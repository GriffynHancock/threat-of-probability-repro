// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ContributorShareRegistry
/// @notice Admin grants contribution weight; holders convert it into shares. Rewards accrue per share.
contract ContributorShareRegistry {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable rewardToken;
    address public immutable admin;

    uint256 public totalShares;
    uint256 public rewardPerShare;

    mapping(address => uint256) public grantedWeight;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public rewardsOwed;

    event WeightGranted(address indexed who, uint256 weight);
    event SharesMinted(address indexed who, uint256 amount);
    event SharesRetired(address indexed who, uint256 amount);
    event RewardsAdded(uint256 amount);
    event RewardsCollected(address indexed who, uint256 amount);

    constructor(IERC20 _reward) {
        rewardToken = _reward;
        admin = msg.sender;
    }

    function grantWeight(address who, uint256 weight) external {
        require(msg.sender == admin, "not admin");
        grantedWeight[who] += weight;
        emit WeightGranted(who, weight);
    }

    function addRewards(uint256 amount) external {
        require(msg.sender == admin, "not admin");
        require(totalShares > 0, "no shares");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        rewardPerShare += (amount * PRECISION) / totalShares;
        emit RewardsAdded(amount);
    }

    /// @dev Settles rewards on the holder's current share count.
    function _rebalanceShares(address who) internal {
        uint256 s = shares[who];
        rewardsOwed[who] += (s * (rewardPerShare - rewardDebt[who])) / PRECISION;
        rewardDebt[who] = rewardPerShare;
    }

    /// @notice Convert granted weight into shares.
    function mintShares(uint256 weight) external {
        require(weight > 0, "zero weight");
        require(grantedWeight[msg.sender] >= weight, "not granted");
        _rebalanceShares(msg.sender);
        shares[msg.sender] += weight;
        totalShares += weight;
        grantedWeight[msg.sender] -= weight;
        emit SharesMinted(msg.sender, weight);
    }

    /// @notice Retire shares; they stop earning. Weight is not returned.
    function retireShares(uint256 amount) external {
        _rebalanceShares(msg.sender);
        require(shares[msg.sender] >= amount, "insufficient shares");
        shares[msg.sender] -= amount;
        totalShares -= amount;
        emit SharesRetired(msg.sender, amount);
    }

    /// @notice Collect rewards accrued on shares.
    function collectRewards() external {
        _rebalanceShares(msg.sender);
        uint256 amount = rewardsOwed[msg.sender];
        require(amount > 0, "nothing to collect");
        rewardsOwed[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amount), "transfer failed");
        emit RewardsCollected(msg.sender, amount);
    }
}
