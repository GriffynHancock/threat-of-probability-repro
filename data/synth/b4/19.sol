// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title PayrollStreamVaultV2
/// @notice Workers prepay escrow; a rate-limited salary stream moves escrow into accrued pay each second.
///         State is kept in parallel mappings rather than a struct.
contract PayrollStreamVaultV2 {
    IERC20 public immutable payToken;
    address public immutable employer;

    mapping(address => uint256) public rateOf;
    mapping(address => uint256) public lastTick;
    mapping(address => uint256) public escrowOf;
    mapping(address => uint256) public accruedOf;
    mapping(address => uint256) public drawnOf;
    uint256 public totalEscrow;

    event RateSet(address indexed worker, uint256 rate);
    event EscrowAdded(address indexed worker, uint256 amount);
    event EscrowRefunded(address indexed worker, uint256 amount);
    event PayDrawn(address indexed worker, uint256 amount);

    constructor(IERC20 _token) {
        payToken = _token;
        employer = msg.sender;
    }

    /// @dev Moves escrow into accrued pay for the elapsed interval, capped at the escrow balance.
    function _tickSalaryStream(address who) internal {
        uint256 last = lastTick[who];
        if (last != 0 && rateOf[who] > 0) {
            uint256 earned = rateOf[who] * (block.timestamp - last);
            uint256 cap = escrowOf[who];
            if (earned > cap) earned = cap;
            escrowOf[who] -= earned;
            totalEscrow -= earned;
            accruedOf[who] += earned;
        }
        lastTick[who] = block.timestamp;
    }

    function setRate(address worker, uint256 rate) external {
        require(msg.sender == employer, "not employer");
        _tickSalaryStream(worker);
        rateOf[worker] = rate;
        emit RateSet(worker, rate);
    }

    /// @notice Prepay escrow against your own future salary.
    function addToEscrow(uint256 amount) external {
        require(amount > 0, "zero amount");
        _tickSalaryStream(msg.sender);
        escrowOf[msg.sender] += amount;
        totalEscrow += amount;
        require(payToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit EscrowAdded(msg.sender, amount);
    }

    /// @notice Refund unvested escrow.
    function refundEscrow(uint256 amount) external {
        _tickSalaryStream(msg.sender);
        require(escrowOf[msg.sender] >= amount, "insufficient escrow");
        escrowOf[msg.sender] -= amount;
        totalEscrow -= amount;
        require(payToken.transfer(msg.sender, amount), "transfer failed");
        emit EscrowRefunded(msg.sender, amount);
    }

    /// @notice Draw accrued pay.
    function drawStream() external {
        _tickSalaryStream(msg.sender);
        uint256 amount = accruedOf[msg.sender] - drawnOf[msg.sender];
        require(amount > 0, "nothing accrued");
        drawnOf[msg.sender] += amount;
        require(payToken.transfer(msg.sender, amount), "transfer failed");
        emit PayDrawn(msg.sender, amount);
    }
}
