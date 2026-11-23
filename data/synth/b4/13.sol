// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title BoundedFeeRebateStaking
/// @notice Bonded tokens earn a fee rebate. Per-settlement rebates are capped at MAX_REBATE_BPS of principal
///         so a single large fee event cannot drain the rebate budget.
contract BoundedFeeRebateStaking {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant MAX_REBATE_BPS = 500;
    uint256 private constant BPS = 10_000;

    struct Bond {
        uint256 amount;
        uint256 debt;
        uint256 rebates;
    }

    IERC20 public immutable token;
    address public immutable feeCollector;
    uint256 public totalBonded;
    uint256 public rebateIndex;

    mapping(address => Bond) public bonds;

    event Bonded(address indexed who, uint256 amount);
    event Unbonded(address indexed who, uint256 amount);
    event FeesAdded(uint256 amount);
    event Rebated(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        feeCollector = msg.sender;
    }

    function addFees(uint256 amount) external {
        require(msg.sender == feeCollector, "not collector");
        require(totalBonded > 0, "no bonds");
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        rebateIndex += (amount * PRECISION) / totalBonded;
        emit FeesAdded(amount);
    }

    function _accrueFeeRebate(address who) internal {
        Bond storage b = bonds[who];
        if (b.amount > 0) {
            uint256 earned = (b.amount * (rebateIndex - b.debt)) / PRECISION;
            uint256 cap = (b.amount * MAX_REBATE_BPS) / BPS;
            if (earned > cap) earned = cap;
            b.rebates += earned;
        }
        b.debt = rebateIndex;
    }

    /// @notice Bond tokens to earn rebates.
    function bond(uint256 amount) external {
        require(amount > 0, "zero amount");
        _accrueFeeRebate(msg.sender);
        Bond storage b = bonds[msg.sender];
        b.amount += amount;
        totalBonded += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Bonded(msg.sender, amount);
    }

    /// @notice Unbond tokens.
    function unbond(uint256 amount) external {
        _accrueFeeRebate(msg.sender);
        Bond storage b = bonds[msg.sender];
        require(b.amount >= amount, "insufficient bond");
        b.amount -= amount;
        totalBonded -= amount;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit Unbonded(msg.sender, amount);
    }

    /// @notice Claim accumulated rebates.
    function rebate() external {
        _accrueFeeRebate(msg.sender);
        Bond storage b = bonds[msg.sender];
        uint256 amount = b.rebates;
        require(amount > 0, "nothing to rebate");
        b.rebates = 0;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit Rebated(msg.sender, amount);
    }
}
