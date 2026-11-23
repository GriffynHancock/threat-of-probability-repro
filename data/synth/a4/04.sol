// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract EscrowLocker {
    error ZeroAmount();
    error BadDuration();
    error StillLocked();
    error OverWithdraw();
    error ReserveLow();
    error Unauthorized();
    error PullFailed();
    error PushFailed();

    uint256 private constant WAD = 1e18;
    uint256 public constant MIN_DURATION = 7 days;
    uint256 public constant MAX_DURATION = 730 days;
    uint256 public constant YIELD_PER_WEIGHT_SECOND = 3e9;

    IERC20Like public immutable token;
    address public immutable treasury;

    uint256 public yieldReserve;

    mapping(address => uint256) public amountOf;
    mapping(address => uint256) public weightOf;
    mapping(address => uint64) public unlockOf;
    mapping(address => uint256) public pendingYield;
    mapping(address => uint256) internal checkpointAt;

    event Bonded(address indexed who, uint256 amount, uint256 duration, uint256 weight);
    event Unbonded(address indexed who, uint256 amount);
    event YieldClaimed(address indexed who, uint256 amount);
    event YieldFunded(uint256 amount);

    constructor(IERC20Like _token) {
        token = _token;
        treasury = msg.sender;
    }

    function bond(uint256 amount, uint256 duration) external returns (uint256 weight) {
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();

        _checkpoint(msg.sender);

        weight = amount * duration / MAX_DURATION;
        if (weight == 0) revert ZeroAmount();

        uint64 end = uint64(block.timestamp + duration);
        if (end > unlockOf[msg.sender]) unlockOf[msg.sender] = end;

        amountOf[msg.sender] += amount;
        weightOf[msg.sender] += weight;

        if (!token.transferFrom(msg.sender, address(this), amount)) revert PullFailed();
        emit Bonded(msg.sender, amount, duration, weight);
    }

    function unbond(uint256 amount) external {
        uint256 held = amountOf[msg.sender];
        if (amount == 0 || amount > held) revert OverWithdraw();
        if (block.timestamp < unlockOf[msg.sender]) revert StillLocked();

        _checkpoint(msg.sender);

        uint256 weightOut = weightOf[msg.sender] * amount / held;
        amountOf[msg.sender] = held - amount;
        weightOf[msg.sender] -= weightOut;

        if (!token.transfer(msg.sender, amount)) revert PushFailed();
        emit Unbonded(msg.sender, amount);
    }

    function claimYield() external returns (uint256 amount) {
        _checkpoint(msg.sender);
        amount = pendingYield[msg.sender];
        if (amount == 0) return 0;
        if (amount > yieldReserve) revert ReserveLow();

        pendingYield[msg.sender] = 0;
        yieldReserve -= amount;
        if (!token.transfer(msg.sender, amount)) revert PushFailed();
        emit YieldClaimed(msg.sender, amount);
    }

    function fundYield(uint256 amount) external {
        if (msg.sender != treasury) revert Unauthorized();
        if (!token.transferFrom(msg.sender, address(this), amount)) revert PullFailed();
        yieldReserve += amount;
        emit YieldFunded(amount);
    }

    function _checkpoint(address who) internal {
        uint256 last = checkpointAt[who];
        checkpointAt[who] = block.timestamp;
        uint256 w = weightOf[who];
        if (last == 0 || w == 0) return;
        pendingYield[who] += w * (block.timestamp - last) * YIELD_PER_WEIGHT_SECOND / WAD;
    }
}
