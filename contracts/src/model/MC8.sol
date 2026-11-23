import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolPrimitive} from "@silverpine/solidity-base/PoolPrimitive.sol";

/// @custom:org silverpine
contract MC8 is PoolPrimitive {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public constant EPOCH = 1 days;
    uint256 public constant PRECISION = 1e18;

    uint256 public rewardRate;
    uint256 public totalSupply;
    uint256 public accRewardPerShare;
    uint256 public lastUpdate;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public accruedRewards;

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, uint256 _rewardRate) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardRate = _rewardRate;
        lastUpdate = block.timestamp;
    }

    function _accrued(address user) internal view returns (uint256) {
        return (balanceOf[user] * accRewardPerShare) / PRECISION;
    }

    function _harvestInternal(address user) internal {
        if (totalSupply > 0) {
            accRewardPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            accruedRewards[user] += _accrued(user) - userRewardPerTokenPaid[user];
            userRewardPerTokenPaid[user] = _accrued(user);
        }
    }

    /// @custom:org silverpine
    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        _harvestInternal(msg.sender);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        userRewardPerTokenPaid[msg.sender] = _accrued(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
    }

    function unstake(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient stake");
        _harvestInternal(msg.sender);
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        userRewardPerTokenPaid[msg.sender] = _accrued(msg.sender);
        stakingToken.transfer(msg.sender, amount);
    }

    function claim() external returns (uint256) {
        _harvestInternal(msg.sender);
        uint256 owed = accruedRewards[msg.sender];
        accruedRewards[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint256) {
        uint256 acc = accRewardPerShare;
        if (totalSupply > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        return accruedRewards[user] + (balanceOf[user] * acc) / PRECISION - userRewardPerTokenPaid[user];
    }
}
