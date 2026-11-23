import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingCore} from "@threatsystems/contracts-core/StakingCore.sol";

/// @custom:org threatsystems
contract MB3 is StakingCore {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public constant EPOCH = 1 days;
    uint256 public constant PRECISION = 1e12;

    uint256 public rewardRate;
    uint256 public totalSupply;
    uint256 public accRewardPerShare;
    uint256 public lastUpdate;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public snapshotIndex;
    mapping(address => uint256) public rewards;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, uint256 _rewardRate) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardRate = _rewardRate;
        lastUpdate = block.timestamp;
    }

    function _indexed(address user) internal view returns (uint256) {
        return (shares[user] * accRewardPerShare) / PRECISION;
    }

    function _updateRewards(address user) internal {
        if (totalSupply > 0) {
            accRewardPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            rewards[user] += _indexed(user) - snapshotIndex[user];
            snapshotIndex[user] = _indexed(user);
        }
    }

    /// @custom:org threatsystems
    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        totalSupply += amount;
        shares[msg.sender] += amount;
        snapshotIndex[msg.sender] = _indexed(msg.sender);
        _updateRewards(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(shares[msg.sender] >= amount, "insufficient stake");
        totalSupply -= amount;
        shares[msg.sender] -= amount;
        snapshotIndex[msg.sender] = _indexed(msg.sender);
        _updateRewards(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint256) {
        _updateRewards(msg.sender);
        uint256 owed = rewards[msg.sender];
        rewards[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint256) {
        uint256 acc = accRewardPerShare;
        if (totalSupply > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        return rewards[user] + (shares[user] * acc) / PRECISION - snapshotIndex[user];
    }
}
