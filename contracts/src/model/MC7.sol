import {IERC20} from "../MockERC20.sol";
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolBase} from "@kestrel-labs/contracts-core/PoolBase.sol";

/// @custom:org kestrel-labs
contract MC7 is PoolBase {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint public constant EPOCH = 7 days;
    uint public constant PRECISION = 1e18;

    uint public rewardRate;
    uint public totalSupply;
    uint public accPerShare;
    uint public lastUpdate;

    mapping(address => uint) public deposits;
    mapping(address => uint) public paidPerShare;
    mapping(address => uint) public accruedRewards;

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
        return (deposits[user] * accPerShare) / PRECISION;
    }

    function _updateReward(address user) internal {
        if (totalSupply > 0) {
            accPerShare += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        lastUpdate = block.timestamp;
        if (user != address(0)) {
            accruedRewards[user] += _shareOf(user) - paidPerShare[user];
            paidPerShare[user] = _shareOf(user);
        }
    }

    /// @custom:org kestrel-labs
    function stake(uint amount) external {
        require(amount > 0, "zero amount");
        _updateReward(msg.sender);
        totalSupply += amount;
        deposits[msg.sender] += amount;
        paidPerShare[msg.sender] = _shareOf(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint amount) external {
        require(deposits[msg.sender] >= amount, "insufficient stake");
        _updateReward(msg.sender);
        totalSupply -= amount;
        deposits[msg.sender] -= amount;
        paidPerShare[msg.sender] = _shareOf(msg.sender);
        stakingToken.transfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external returns (uint) {
        _updateReward(msg.sender);
        uint owed = accruedRewards[msg.sender];
        accruedRewards[msg.sender] = 0;
        rewardToken.transfer(msg.sender, owed);
        emit Claimed(msg.sender, owed);
        return owed;
    }

    function earned(address user) external view returns (uint) {
        uint acc = accPerShare;
        if (totalSupply > 0) {
            acc += ((block.timestamp - lastUpdate) * rewardRate * PRECISION) / totalSupply;
        }
        return accruedRewards[user] + (deposits[user] * acc) / PRECISION - paidPerShare[user];
    }
}
