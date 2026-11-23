// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Vote-escrow style locks. Voting weight decays linearly toward the unlock time.
contract VoteEscrowLock {
    uint256 public constant MAX_LOCK = 4 * 365 days;
    uint256 public constant MIN_LOCK = 7 days;

    struct Position {
        uint256 amount;
        uint256 end;
        uint256 cachedWeight;
    }

    IERC20 public immutable token;
    uint256 public totalWeight;
    uint256 public totalLocked;

    mapping(address => Position) public positions;
    mapping(address => uint256) public claimable;

    event Locked(address indexed user, uint256 amount, uint256 end, uint256 weight);
    event Unlocked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
    }

    function _currentWeight(Position storage p) internal view returns (uint256) {
        if (p.end <= block.timestamp) return 0;
        return (p.amount * (p.end - block.timestamp)) / MAX_LOCK;
    }

    function _syncWeight(address who) internal {
        Position storage p = positions[who];
        uint256 w = _currentWeight(p);
        totalWeight = totalWeight - p.cachedWeight + w;
        p.cachedWeight = w;
    }

    function lock(uint256 amount, uint256 duration) external {
        require(amount > 0, "zero");
        require(duration >= MIN_LOCK && duration <= MAX_LOCK, "duration");
        _syncWeight(msg.sender);
        Position storage p = positions[msg.sender];
        p.amount += amount;
        uint256 newEnd = block.timestamp + duration;
        if (newEnd > p.end) p.end = newEnd;
        totalLocked += amount;
        uint256 w = _currentWeight(p);
        totalWeight = totalWeight - p.cachedWeight + w;
        p.cachedWeight = w;
        emit Locked(msg.sender, amount, p.end, w);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function unlock() external returns (uint256 amount) {
        _syncWeight(msg.sender);
        Position storage p = positions[msg.sender];
        require(p.amount > 0, "no position");
        require(block.timestamp >= p.end, "still locked");
        amount = p.amount;
        totalLocked -= amount;
        claimable[msg.sender] += amount;
        delete positions[msg.sender];
        emit Unlocked(msg.sender, amount);
    }

    function claim() external returns (uint256 amount) {
        amount = claimable[msg.sender];
        require(amount > 0, "nothing");
        claimable[msg.sender] = 0;
        emit Claimed(msg.sender, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }

    function weightOf(address who) external view returns (uint256) {
        return _currentWeight(positions[who]);
    }
}
