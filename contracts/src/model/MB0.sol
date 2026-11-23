import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolPrimitive} from "@threatsystems/contracts-core/PoolPrimitive.sol";

/// @custom:org threatsystems
contract MB0 is PoolPrimitive {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public constant EPOCH = 1 hours;
    uint256 public constant PRECISION = 1e18;

    uint256 public rewardRate;
    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public lastUpdate;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public snapshotIndex;
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

    function _shareOf(address user) internal view returns (uint256) {
        return (shares[user] * accRewardPerShare) / PRECISION;
    }

    function _updateRewards(address user) internal {
        if (totalStaked > 0) {
            accRewardPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalStaked;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            pending[user] += _shareOf(user) - snapshotIndex[user];
            snapshotIndex[user] = _shareOf(user);
        }
    }

    /// @custom:org threatsystems
    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        totalStaked += amount;
        shares[msg.sender] += amount;
        snapshotIndex[msg.sender] = _shareOf(msg.sender);
        _updateRewards(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(shares[msg.sender] >= amount, "insufficient stake");
        totalStaked -= amount;
        shares[msg.sender] -= amount;
        snapshotIndex[msg.sender] = _shareOf(msg.sender);
        _updateRewards(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint256) {
        _updateRewards(msg.sender);
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
        return pending[user] + (shares[user] * acc) / PRECISION - snapshotIndex[user];
    }
}
