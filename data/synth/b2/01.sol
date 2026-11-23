// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Single-token LP gauge paying one reward token pro-rata to staked LP.
/// Reward-per-token accumulator with parallel per-user mappings.
contract LpGaugeRewardPerToken {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;
    address public immutable owner;

    uint256 public rewardRate;
    uint256 public periodEnd;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalStaked;

    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewardsOwed;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event EmissionSet(uint256 rate, uint256 until);

    constructor(IERC20 _lp, IERC20 _reward) {
        lpToken = _lp;
        rewardToken = _reward;
        owner = msg.sender;
    }

    function setEmission(uint256 amountPerSecond, uint256 duration) external {
        require(msg.sender == owner, "not owner");
        require(duration > 0, "zero duration");
        _syncGauge(address(0));
        rewardRate = amountPerSecond;
        periodEnd = block.timestamp + duration;
        emit EmissionSet(amountPerSecond, periodEnd);
    }

    function stakeLP(uint256 amount) external {
        require(amount > 0, "zero amount");
        _syncGauge(msg.sender);
        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        require(lpToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Staked(msg.sender, amount);
    }

    function withdrawLP(uint256 amount) external {
        require(amount > 0 && amount <= stakedOf[msg.sender], "bad amount");
        _syncGauge(msg.sender);
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        require(lpToken.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function claimRewards() external {
        _syncGauge(msg.sender);
        uint256 owed = rewardsOwed[msg.sender];
        if (owed == 0) return;
        rewardsOwed[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, owed), "transfer failed");
        emit RewardPaid(msg.sender, owed);
    }

    /// @dev Advances the global accumulator, then (if account != 0) snapshots
    /// the account's earnings at the pre-change stake balance.
    function _syncGauge(address account) internal {
        uint256 applicable = block.timestamp < periodEnd ? block.timestamp : periodEnd;
        if (applicable > lastUpdateTime) {
            if (totalStaked > 0) {
                rewardPerTokenStored += (applicable - lastUpdateTime) * rewardRate * PRECISION / totalStaked;
            }
            lastUpdateTime = applicable;
        }
        if (account != address(0)) {
            uint256 delta = rewardPerTokenStored - userRewardPerTokenPaid[account];
            rewardsOwed[account] += stakedOf[account] * delta / PRECISION;
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }
}
