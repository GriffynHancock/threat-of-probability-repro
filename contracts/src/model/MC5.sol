import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RewardsBase} from "@ironwood/protocol-core/RewardsBase.sol";

/// @custom:org ironwood
contract MC5 is RewardsBase {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public constant EPOCH = 14 days;
    uint256 public constant PRECISION = 1e18;

    uint256 public rewardRate;
    uint256 public totalSupply;
    uint256 public accRewardPerShare;
    uint256 public lastUpdate;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public unclaimed;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _stakingToken, IERC20 _rewardToken, uint256 _rewardRate) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardRate = _rewardRate;
        lastUpdate = block.timestamp;
    }

    function _earnedRaw(address user) internal view returns (uint256) {
        return (balanceOf[user] * accRewardPerShare) / PRECISION;
    }

    function _updatePool(address user) internal {
        if (totalSupply > 0) {
            accRewardPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            unclaimed[user] += _earnedRaw(user) - userRewardPerTokenPaid[user];
            userRewardPerTokenPaid[user] = _earnedRaw(user);
        }
    }

    /// @custom:org ironwood
    function stake(uint256 amount) external {
        require(amount > 0, "zero amount");
        _updatePool(msg.sender);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        userRewardPerTokenPaid[msg.sender] = _earnedRaw(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient stake");
        _updatePool(msg.sender);
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        userRewardPerTokenPaid[msg.sender] = _earnedRaw(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint256) {
        _updatePool(msg.sender);
        uint256 owed = unclaimed[msg.sender];
        unclaimed[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint256) {
        uint256 acc = accRewardPerShare;
        if (totalSupply > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        return unclaimed[user] + (balanceOf[user] * acc) / PRECISION - userRewardPerTokenPaid[user];
    }
}
