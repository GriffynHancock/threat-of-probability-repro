// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

error ZeroAmount();
error OperatorInactive(address operator);
error NotOwner();
error InsufficientDelegation(uint256 have, uint256 want);
error NotReady(uint256 readyAt);

/// @notice Per-operator delegation book. Stakers delegate to operators and earn pro-rata operator rewards.
contract OperatorDelegationBook {
    uint256 private constant PRECISION = 1e27;
    uint256 public constant UNDELEGATE_DELAY = 3 days;

    struct Operator {
        bool active;
        uint256 totalShares;
        uint256 rewardIndex;
        uint256 pendingRewards;
    }

    struct Position {
        uint256 shares;
        uint256 indexPaid;
        uint256 owed;
    }

    struct Exit {
        uint256 amount;
        uint256 readyAt;
    }

    IERC20 public immutable token;
    address public immutable owner;

    mapping(address => Operator) public operators;
    mapping(address => mapping(address => Position)) public positions;
    mapping(address => mapping(address => Exit)) public exits;

    event OperatorRegistered(address indexed operator);
    event Delegated(address indexed staker, address indexed operator, uint256 amount);
    event UndelegateRequested(address indexed staker, address indexed operator, uint256 amount, uint256 readyAt);
    event UndelegateCompleted(address indexed staker, address indexed operator, uint256 amount);
    event RewardsReported(address indexed operator, uint256 amount);
    event RewardsClaimed(address indexed staker, address indexed operator, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function registerOperator(address op) external onlyOwner {
        operators[op].active = true;
        emit OperatorRegistered(op);
    }

    function reportRewards(address op, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        Operator storage o = operators[op];
        if (!o.active) revert OperatorInactive(op);
        o.pendingRewards += amount;
        emit RewardsReported(op, amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function _settleOperator(address op) internal {
        Operator storage o = operators[op];
        if (o.pendingRewards == 0 || o.totalShares == 0) return;
        o.rewardIndex += (o.pendingRewards * PRECISION) / o.totalShares;
        o.pendingRewards = 0;
    }

    function _accrueStakerRewards(address op, address staker) internal {
        Position storage p = positions[op][staker];
        uint256 idx = operators[op].rewardIndex;
        p.owed += (p.shares * (idx - p.indexPaid)) / PRECISION;
        p.indexPaid = idx;
    }

    function delegate(address op, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!operators[op].active) revert OperatorInactive(op);
        _settleOperator(op);
        _accrueStakerRewards(op, msg.sender);
        Position storage p = positions[op][msg.sender];
        p.shares += amount;
        operators[op].totalShares += amount;
        emit Delegated(msg.sender, op, amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function requestUndelegate(address op, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _settleOperator(op);
        _accrueStakerRewards(op, msg.sender);
        Position storage p = positions[op][msg.sender];
        if (p.shares < amount) revert InsufficientDelegation(p.shares, amount);
        p.shares -= amount;
        operators[op].totalShares -= amount;
        Exit storage e = exits[op][msg.sender];
        e.amount += amount;
        e.readyAt = block.timestamp + UNDELEGATE_DELAY;
        emit UndelegateRequested(msg.sender, op, amount, e.readyAt);
    }

    function completeUndelegate(address op) external {
        Exit storage e = exits[op][msg.sender];
        uint256 amount = e.amount;
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < e.readyAt) revert NotReady(e.readyAt);
        e.amount = 0;
        e.readyAt = 0;
        emit UndelegateCompleted(msg.sender, op, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }

    function claimRewards(address op) external returns (uint256 amount) {
        _settleOperator(op);
        _accrueStakerRewards(op, msg.sender);
        Position storage p = positions[op][msg.sender];
        amount = p.owed;
        p.owed = 0;
        if (amount > 0) {
            require(token.transfer(msg.sender, amount), "xfer");
        }
        emit RewardsClaimed(msg.sender, op, amount);
    }
}
