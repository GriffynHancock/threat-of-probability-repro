import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StakingCore} from "@threatsystems/solidity-base/StakingCore.sol";

/// @custom:org threatsystems
contract MB1 is StakingCore {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint public constant EPOCH = 1 hours;
    uint public constant PRECISION = 1e18;

    uint public rewardRate;
    uint public totalSupply;
    uint public accRewardPerShare;
    uint public lastUpdate;

    mapping(address => uint) public shares;
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

    function _indexed(address user) internal view returns (uint) {
        return (shares[user] * accRewardPerShare) / PRECISION;
    }

    function _updatePool(address user) internal {
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
    function deposit(uint amount) external {
        require(amount > 0, "zero amount");
        totalSupply += amount;
        shares[msg.sender] += amount;
        snapshotIndex[msg.sender] = _indexed(msg.sender);
        _updatePool(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint amount) external {
        require(shares[msg.sender] >= amount, "insufficient stake");
        totalSupply -= amount;
        shares[msg.sender] -= amount;
        snapshotIndex[msg.sender] = _indexed(msg.sender);
        _updatePool(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint) {
        _updatePool(msg.sender);
        uint owed = rewards[msg.sender];
        rewards[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint) {
        uint acc = accRewardPerShare;
        if (totalSupply > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        return rewards[user] + (shares[user] * acc) / PRECISION - snapshotIndex[user];
    }
}
