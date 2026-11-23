import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolPrimitive} from "@silverpine/protocol-core/PoolPrimitive.sol";

/// @custom:org silverpine
contract MC2 is PoolPrimitive {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint public constant EPOCH = 30 days;
    uint public constant PRECISION = 1e12;

    uint public rewardRate;
    uint public totalStaked;
    uint public accPerShare;
    uint public lastUpdate;

    mapping(address => uint) public balanceOf;
    mapping(address => uint) public snapshotIndex;
    mapping(address => uint) public rewards;

    event Staked(address indexed user, uint amount);
    event Unstaked(address indexed user, uint amount);
    event Claimed(address indexed user, uint amount);

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, uint _rewardRate) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardRate = _rewardRate;
        lastUpdate = block.timestamp;
    }

    function _shareOf(address user) internal view returns (uint) {
        return (balanceOf[user] * accPerShare) / PRECISION;
    }

    function _updateReward(address user) internal {
        if (totalStaked > 0) {
            accPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalStaked;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            rewards[user] += _shareOf(user) - snapshotIndex[user];
            snapshotIndex[user] = _shareOf(user);
        }
    }

    /// @custom:org silverpine
    function deposit(uint amount) external {
        require(amount > 0, "zero amount");
        _updateReward(msg.sender);
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        snapshotIndex[msg.sender] = _shareOf(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient stake");
        _updateReward(msg.sender);
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        snapshotIndex[msg.sender] = _shareOf(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint) {
        _updateReward(msg.sender);
        uint owed = rewards[msg.sender];
        rewards[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint) {
        uint acc = accPerShare;
        if (totalStaked > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalStaked;
        }
        return rewards[user] + (balanceOf[user] * acc) / PRECISION - snapshotIndex[user];
    }
}
