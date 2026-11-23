import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolPrimitive} from "@arcadia-fi/contracts-core/PoolPrimitive.sol";

/// @custom:org arcadia-fi
contract MC3 is PoolPrimitive {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint public constant EPOCH = 1 days;
    uint public constant PRECISION = 1e12;

    uint public rewardRate;
    uint public totalSupply;
    uint public accRewardPerShare;
    uint public lastUpdate;

    mapping(address => uint) public balanceOf;
    mapping(address => uint) public userRewardPerTokenPaid;
    mapping(address => uint) public rewards;

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, uint _rewardRate) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardRate = _rewardRate;
        lastUpdate = block.timestamp;
    }

    function _shareOf(address user) internal view returns (uint) {
        return (balanceOf[user] * accRewardPerShare) / PRECISION;
    }

    function _harvestInternal(address user) internal {
        if (totalSupply > 0) {
            accRewardPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            rewards[user] += _shareOf(user) - userRewardPerTokenPaid[user];
            userRewardPerTokenPaid[user] = _shareOf(user);
        }
    }

    /// @custom:org arcadia-fi
    function stake(uint amount) external {
        require(amount > 0, "zero amount");
        _harvestInternal(msg.sender);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        userRewardPerTokenPaid[msg.sender] = _shareOf(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient stake");
        _harvestInternal(msg.sender);
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        userRewardPerTokenPaid[msg.sender] = _shareOf(msg.sender);
        stakingToken.transfer(msg.sender, amount);
    }

    function claim() external returns (uint) {
        _harvestInternal(msg.sender);
        uint owed = rewards[msg.sender];
        rewards[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint) {
        uint acc = accRewardPerShare;
        if (totalSupply > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        return rewards[user] + (balanceOf[user] * acc) / PRECISION - userRewardPerTokenPaid[user];
    }
}
