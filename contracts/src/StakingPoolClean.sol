// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./MockERC20.sol";

/// @title StakingPool
/// @notice Epoch-based staking pool. Stakers accrue reward tokens per second,
///         pro rata to their share of the pool.
contract StakingPoolClean {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public constant EPOCH = 7 days;
    uint256 public constant PRECISION = 1e18;

    uint256 public rewardRate;
    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public lastUpdate;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pending;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, uint256 _rewardRate) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardRate = _rewardRate;
        lastUpdate = block.timestamp;
    }

    function _accrued(address user) internal view returns (uint256) {
        return (balanceOf[user] * accRewardPerShare) / PRECISION;
    }

    function _checkpoint(address user) internal {
        if (totalStaked > 0) {
            accRewardPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalStaked;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            pending[user] += _accrued(user) - rewardDebt[user];
            rewardDebt[user] = _accrued(user);
        }
    }

    function stake(uint256 amount) external {
        require(amount > 0, "zero amount");
        _checkpoint(msg.sender);
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        rewardDebt[msg.sender] = _accrued(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient stake");
        _checkpoint(msg.sender);
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        rewardDebt[msg.sender] = _accrued(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint256) {
        _checkpoint(msg.sender);
        uint256 owed = pending[msg.sender];
        pending[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint256) {
        uint256 acc = accRewardPerShare;
        if (totalStaked > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalStaked;
        }
        return pending[user] + (balanceOf[user] * acc) / PRECISION - rewardDebt[user];
    }
}
