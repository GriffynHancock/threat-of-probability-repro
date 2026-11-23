// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice LP pool with lock-tier multipliers. Rewards are pro rata to weight (amount x multiplier).
contract WeightedLockPool {
    uint256 private constant ACC = 1e12;

    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;
    uint256 public immutable rewardPerBlock;

    uint256 public lastRewardBlock;
    uint256 public accRewardPerWeight;
    uint256 public totalWeight;

    uint256[3] public multiplier = [uint256(1), 2, 3];

    struct UserInfo {
        uint256 amount;
        uint256 weight;
        uint256 rewardDebt;
        uint256 unclaimed;
    }
    mapping(address => UserInfo) public users;

    event Deposit(address indexed user, uint256 amount, uint8 tier);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 amount);

    constructor(IERC20 _lp, IERC20 _reward, uint256 _rewardPerBlock) {
        lpToken = _lp;
        rewardToken = _reward;
        rewardPerBlock = _rewardPerBlock;
        lastRewardBlock = block.number;
    }

    function _updatePool() internal {
        if (block.number <= lastRewardBlock) return;
        if (totalWeight == 0) {
            lastRewardBlock = block.number;
            return;
        }
        uint256 blocksElapsed = block.number - lastRewardBlock;
        accRewardPerWeight += (blocksElapsed * rewardPerBlock * ACC) / totalWeight;
        lastRewardBlock = block.number;
    }

    function _harvestUser(address who) internal {
        UserInfo storage u = users[who];
        if (u.weight > 0) {
            u.unclaimed += (u.weight * accRewardPerWeight) / ACC - u.rewardDebt;
        }
        u.rewardDebt = (u.weight * accRewardPerWeight) / ACC;
    }

    function deposit(uint256 lpAmount, uint8 tier) external {
        require(tier < 3, "bad tier");
        _updatePool();
        _harvestUser(msg.sender);
        UserInfo storage u = users[msg.sender];
        uint256 w = lpAmount * multiplier[tier];
        u.amount += lpAmount;
        u.weight += w;
        totalWeight += w;
        u.rewardDebt = (u.weight * accRewardPerWeight) / ACC;
        require(lpToken.transferFrom(msg.sender, address(this), lpAmount), "pull failed");
        emit Deposit(msg.sender, lpAmount, tier);
    }

    function withdraw(uint256 lpAmount) external {
        _updatePool();
        _harvestUser(msg.sender);
        UserInfo storage u = users[msg.sender];
        require(u.amount >= lpAmount, "insufficient");
        uint256 w = (u.weight * lpAmount) / u.amount;
        u.amount -= lpAmount;
        u.weight -= w;
        totalWeight -= w;
        u.rewardDebt = (u.weight * accRewardPerWeight) / ACC;
        require(lpToken.transfer(msg.sender, lpAmount), "push failed");
        emit Withdraw(msg.sender, lpAmount);
    }

    function harvest() external {
        _updatePool();
        _harvestUser(msg.sender);
        UserInfo storage u = users[msg.sender];
        uint256 amount = u.unclaimed;
        require(amount > 0, "nothing");
        u.unclaimed = 0;
        require(rewardToken.transfer(msg.sender, amount), "push failed");
        emit Harvest(msg.sender, amount);
    }
}
