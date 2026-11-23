import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolPrimitive} from "@ironwood/core/PoolPrimitive.sol";

/// @custom:org ironwood
contract MC4 is PoolPrimitive {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public constant EPOCH = 30 days;
    uint256 public constant PRECISION = 1e18;

    uint256 public rewardRate;
    uint256 public totalDeposits;
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

    function _indexed(address user) internal view returns (uint256) {
        return (balanceOf[user] * accRewardPerShare) / PRECISION;
    }

    function _sync(address user) internal {
        if (totalDeposits > 0) {
            accRewardPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalDeposits;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            unclaimed[user] += _indexed(user) - userRewardPerTokenPaid[user];
            userRewardPerTokenPaid[user] = _indexed(user);
        }
    }

    /// @custom:org ironwood
    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        _sync(msg.sender);
        totalDeposits += amount;
        balanceOf[msg.sender] += amount;
        userRewardPerTokenPaid[msg.sender] = _indexed(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient stake");
        _sync(msg.sender);
        totalDeposits -= amount;
        balanceOf[msg.sender] -= amount;
        userRewardPerTokenPaid[msg.sender] = _indexed(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint256) {
        _sync(msg.sender);
        uint256 owed = unclaimed[msg.sender];
        unclaimed[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint256) {
        uint256 acc = accRewardPerShare;
        if (totalDeposits > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalDeposits;
        }
        return unclaimed[user] + (balanceOf[user] * acc) / PRECISION - userRewardPerTokenPaid[user];
    }
}
