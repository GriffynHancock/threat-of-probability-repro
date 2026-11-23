// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Vote-lock style LP escrow. A single lock per account; locked
/// amounts accrue a time-based reward and lock duration sets the unlock time.
contract LockedLpEscrow {
    uint256 private constant RATE_PER_SECOND_PER_UNIT = 1e9;
    uint256 private constant PRECISION = 1e18;
    uint256 public constant MIN_LOCK = 1 weeks;
    uint256 public constant MAX_LOCK = 4 * 365 days;

    struct Lock {
        uint256 amount;
        uint256 unlockAt;
        uint256 lastAccrual;
        uint256 pending;
    }

    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;

    uint256 public totalLocked;
    mapping(address => Lock) public locks;

    event LockExtended(address indexed user, uint256 amount, uint256 unlockAt);
    event Unlocked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);

    constructor(IERC20 _lp, IERC20 _reward) {
        lpToken = _lp;
        rewardToken = _reward;
    }

    function lockLP(uint256 amount, uint256 duration) external {
        require(amount > 0, "zero amount");
        require(duration >= MIN_LOCK && duration <= MAX_LOCK, "bad duration");
        _settleLocks(msg.sender);
        Lock storage l = locks[msg.sender];
        uint256 target = block.timestamp + duration;
        if (target > l.unlockAt) {
            l.unlockAt = target;
        }
        l.amount += amount;
        totalLocked += amount;
        require(lpToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit LockExtended(msg.sender, amount, l.unlockAt);
    }

    function unlockLP(uint256 amount) external {
        Lock storage l = locks[msg.sender];
        require(block.timestamp >= l.unlockAt, "still locked");
        require(amount <= l.amount, "insufficient locked");
        _settleLocks(msg.sender);
        l.amount -= amount;
        totalLocked -= amount;
        require(lpToken.transfer(msg.sender, amount), "transfer failed");
        emit Unlocked(msg.sender, amount);
    }

    function claimLockRewards() external {
        _settleLocks(msg.sender);
        Lock storage l = locks[msg.sender];
        uint256 amount = l.pending;
        if (amount == 0) return;
        l.pending = 0;
        require(rewardToken.transfer(msg.sender, amount), "transfer failed");
        emit RewardClaimed(msg.sender, amount);
    }

    /// @dev Accrues reward on the locked amount for the time elapsed since the
    /// last accrual. Reward is not earned on time after unlockAt.
    function _settleLocks(address user) internal {
        Lock storage l = locks[user];
        if (l.lastAccrual == 0) {
            l.lastAccrual = block.timestamp;
            return;
        }
        uint256 end = block.timestamp < l.unlockAt ? block.timestamp : l.unlockAt;
        if (end > l.lastAccrual && l.amount > 0) {
            uint256 elapsed = end - l.lastAccrual;
            l.pending += l.amount * elapsed * RATE_PER_SECOND_PER_UNIT / PRECISION;
        }
        l.lastAccrual = block.timestamp;
    }
}
