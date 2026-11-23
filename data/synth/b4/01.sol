// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title VeRevenueShare
/// @notice Lock governance tokens for voting power; locked holders share protocol revenue.
contract VeRevenueShare {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant MAX_LOCK = 4 * 365 days;

    IERC20 public immutable govToken;
    IERC20 public immutable revenueToken;

    struct Lock {
        uint256 amount;
        uint256 unlockTime;
        uint256 votingPower;
        uint256 revenueDebt;
        uint256 claimable;
    }

    mapping(address => Lock) public locks;
    uint256 public totalVotingPower;
    uint256 public revenueIndex;

    event Locked(address indexed user, uint256 amount, uint256 unlockTime);
    event Unlocked(address indexed user, uint256 amount);
    event RevenueDeposited(uint256 amount, uint256 newIndex);
    event RevenueClaimed(address indexed user, uint256 amount);

    constructor(IERC20 _gov, IERC20 _revenue) {
        govToken = _gov;
        revenueToken = _revenue;
    }

    /// @notice Distribute revenue pro rata to current voting power.
    function depositRevenue(uint256 amount) external {
        require(totalVotingPower > 0, "no voting power");
        require(revenueToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        revenueIndex += (amount * PRECISION) / totalVotingPower;
        emit RevenueDeposited(amount, revenueIndex);
    }

    function _checkpointVotingPower(address who) internal {
        Lock storage l = locks[who];
        uint256 accrued = (l.votingPower * (revenueIndex - l.revenueDebt)) / PRECISION;
        l.claimable += accrued;
        l.revenueDebt = revenueIndex;
    }

    /// @notice Lock tokens for a duration; voting power scales linearly with remaining time.
    function lock(uint256 amount, uint256 duration) external {
        require(amount > 0, "zero amount");
        require(duration > 0 && duration <= MAX_LOCK, "bad duration");
        _checkpointVotingPower(msg.sender);
        Lock storage l = locks[msg.sender];
        l.amount += amount;
        uint256 newUnlock = block.timestamp + duration;
        if (newUnlock > l.unlockTime) l.unlockTime = newUnlock;
        uint256 newPower = (l.amount * (l.unlockTime - block.timestamp)) / MAX_LOCK;
        totalVotingPower = totalVotingPower - l.votingPower + newPower;
        l.votingPower = newPower;
        require(govToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Locked(msg.sender, amount, l.unlockTime);
    }

    /// @notice Withdraw all locked tokens once the lock has expired.
    function unlock() external {
        _checkpointVotingPower(msg.sender);
        Lock storage l = locks[msg.sender];
        require(block.timestamp >= l.unlockTime, "still locked");
        uint256 amount = l.amount;
        require(amount > 0, "nothing locked");
        l.amount -= amount;
        totalVotingPower -= l.votingPower;
        l.votingPower = 0;
        require(govToken.transfer(msg.sender, amount), "transfer failed");
        emit Unlocked(msg.sender, amount);
    }

    /// @notice Claim accumulated revenue share.
    function claimRevenue() external {
        _checkpointVotingPower(msg.sender);
        Lock storage l = locks[msg.sender];
        uint256 amount = l.claimable;
        require(amount > 0, "nothing to claim");
        l.claimable = 0;
        require(revenueToken.transfer(msg.sender, amount), "transfer failed");
        emit RevenueClaimed(msg.sender, amount);
    }
}
