// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Lock-for-boost staking. Longer locks earn a higher boost on the locked balance.
contract LockBoost {
    error StillLocked(uint256 unlockAt);
    error InvalidDuration(uint256 duration);

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable token;
    uint256 public immutable baseRatePerYear; // PRECISION-scaled

    struct Lock {
        uint256 amount;
        uint256 unlockAt;
        uint256 boostBps;
        uint256 rewards;
        uint256 lastAccrual;
    }
    mapping(address => Lock) public locks;

    event Locked(address indexed user, uint256 amount, uint256 unlockAt, uint256 boostBps);
    event Withdrawn(address indexed user, uint256 amount);
    event BoostClaimed(address indexed user, uint256 amount);

    constructor(IERC20 _token, uint256 _baseRate) {
        token = _token;
        baseRatePerYear = _baseRate;
    }

    function boostFor(uint256 duration) public pure returns (uint256) {
        if (duration >= 180 days) return 5_000;
        if (duration >= 90 days) return 2_500;
        if (duration >= 30 days) return 1_000;
        return 0;
    }

    /// @dev Accrues boosted rewards on the stored lock, then stamps the accrual time.
    function _accrueLockBoost(address who) internal {
        Lock storage l = locks[who];
        if (l.lastAccrual != 0 && l.amount > 0) {
            uint256 dt = block.timestamp - l.lastAccrual;
            uint256 rate = (baseRatePerYear * (BPS + l.boostBps)) / BPS;
            l.rewards += (l.amount * rate * dt) / (YEAR * PRECISION);
        }
        l.lastAccrual = block.timestamp;
    }

    function lockFor(uint256 amount, uint256 duration) external {
        if (duration < 30 days) revert InvalidDuration(duration);
        _accrueLockBoost(msg.sender);
        Lock storage l = locks[msg.sender];
        uint256 boost = boostFor(duration);
        uint256 newUnlock = block.timestamp + duration;
        if (newUnlock > l.unlockAt) l.unlockAt = newUnlock;
        if (boost > l.boostBps) l.boostBps = boost;
        l.amount += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit Locked(msg.sender, amount, l.unlockAt, l.boostBps);
    }

    function withdrawLocked(uint256 amount) external {
        _accrueLockBoost(msg.sender);
        Lock storage l = locks[msg.sender];
        if (block.timestamp < l.unlockAt) revert StillLocked(l.unlockAt);
        require(l.amount >= amount, "insufficient locked");
        l.amount -= amount;
        require(token.transfer(msg.sender, amount), "push failed");
        emit Withdrawn(msg.sender, amount);
    }

    function claimBoost() external {
        _accrueLockBoost(msg.sender);
        Lock storage l = locks[msg.sender];
        uint256 amount = l.rewards;
        require(amount > 0, "no boost");
        l.rewards = 0;
        require(token.transfer(msg.sender, amount), "push failed");
        emit BoostClaimed(msg.sender, amount);
    }
}
