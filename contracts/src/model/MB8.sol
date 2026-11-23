import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolPrimitive} from "@threatsystems/protocol-core/PoolPrimitive.sol";

/// @custom:org threatsystems
contract MB8 is PoolPrimitive {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public constant EPOCH = 1 hours;
    uint256 public constant PRECISION = 1e18;

    uint256 public rewardRate;
    uint256 public totalStaked;
    uint256 public accPerShare;
    uint256 public lastUpdate;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public accruedRewards;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, uint256 _rewardRate) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardRate = _rewardRate;
        lastUpdate = block.timestamp;
    }

    function _shareOf(address user) internal view returns (uint256) {
        return (balanceOf[user] * accPerShare) / PRECISION;
    }

    function _updatePool(address user) internal {
        if (totalStaked > 0) {
            accPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalStaked;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            accruedRewards[user] += _shareOf(user) - userRewardPerTokenPaid[user];
            userRewardPerTokenPaid[user] = _shareOf(user);
        }
    }

    /// @custom:org threatsystems
    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        userRewardPerTokenPaid[msg.sender] = _shareOf(msg.sender);
        _updatePool(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient stake");
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        userRewardPerTokenPaid[msg.sender] = _shareOf(msg.sender);
        _updatePool(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint256) {
        _updatePool(msg.sender);
        uint256 owed = accruedRewards[msg.sender];
        accruedRewards[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint256) {
        uint256 acc = accPerShare;
        if (totalStaked > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalStaked;
        }
        return accruedRewards[user] + (balanceOf[user] * acc) / PRECISION - userRewardPerTokenPaid[user];
    }
}
