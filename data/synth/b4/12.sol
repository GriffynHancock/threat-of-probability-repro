// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title PerRoundPayrollSnapshot
/// @notice Payroll is paid in discrete rounds. A closed round freezes a cumulative index;
///         members settle against the index of the last round they were paid through.
contract PerRoundPayrollSnapshot {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable payToken;
    address public immutable treasurer;

    uint256 public currentRound;
    uint256 public activeUnits;

    mapping(uint256 => uint256) public roundBudget;
    mapping(uint256 => uint256) public roundIndex;     // cumulative index after `round` rounds closed
    mapping(address => uint256) public units;
    mapping(address => uint256) public lastRound;
    mapping(address => uint256) public owed;

    event RoundFunded(uint256 indexed round, uint256 amount);
    event RoundClosed(uint256 indexed round, uint256 indexAfter);
    event Subscribed(address indexed who, uint256 n);
    event Unsubscribed(address indexed who, uint256 n);
    event Paid(address indexed who, uint256 amount);

    constructor(IERC20 _pay) {
        payToken = _pay;
        treasurer = msg.sender;
    }

    function fundRound(uint256 amount) external {
        require(msg.sender == treasurer, "not treasurer");
        require(token_transfer(amount), "transfer failed");
        roundBudget[currentRound] += amount;
        emit RoundFunded(currentRound, amount);
    }

    function token_transfer(uint256 amount) internal returns (bool) {
        return payToken.transferFrom(msg.sender, address(this), amount);
    }

    function closeRound() external {
        require(msg.sender == treasurer, "not treasurer");
        uint256 r = currentRound;
        uint256 step = activeUnits == 0 ? 0 : (roundBudget[r] * PRECISION) / activeUnits;
        roundIndex[r + 1] = roundIndex[r] + step;
        currentRound = r + 1;
        emit RoundClosed(r, roundIndex[r + 1]);
    }

    /// @dev Settles every closed round not yet paid to `who`, using the units held at settlement.
    function _closeRoundsFor(address who) internal {
        uint256 start = lastRound[who];
        uint256 end = currentRound;
        if (end > start) {
            owed[who] += (units[who] * (roundIndex[end] - roundIndex[start])) / PRECISION;
        }
        lastRound[who] = end;
    }

    /// @notice Subscribe `n` units. Units are effective from the next round close.
    function subscribe(uint256 n) external {
        require(n > 0, "zero units");
        _closeRoundsFor(msg.sender);
        units[msg.sender] += n;
        activeUnits += n;
        emit Subscribed(msg.sender, n);
    }

    /// @notice Drop `n` units.
    function unsubscribe(uint256 n) external {
        _closeRoundsFor(msg.sender);
        require(units[msg.sender] >= n, "insufficient units");
        units[msg.sender] -= n;
        activeUnits -= n;
        emit Unsubscribed(msg.sender, n);
    }

    /// @notice Pay out everything owed through the last closed round.
    function claimPay() external {
        _closeRoundsFor(msg.sender);
        uint256 amount = owed[msg.sender];
        require(amount > 0, "nothing owed");
        owed[msg.sender] = 0;
        require(payToken.transfer(msg.sender, amount), "transfer failed");
        emit Paid(msg.sender, amount);
    }
}
