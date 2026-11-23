// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title StakingRewardsClassic
/// @notice Single-token staking with a finite, owner-funded reward period.
/// @dev Reward accounting uses a global reward-per-token accumulator. Each
///      account stores the accumulator value it was last settled at.
contract StakingRewardsClassic {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant REWARD_DURATION = 7 days;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;
    address public owner;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 reward, uint256 rate, uint256 periodFinish);

    modifier onlyOwner() {
        require(msg.sender == owner, "StakingRewardsClassic: not owner");
        _;
    }

    /// @dev Settles global and per-account reward state before the body runs.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(address _stakingToken, address _rewardsToken) {
        require(_stakingToken != address(0) && _rewardsToken != address(0), "StakingRewardsClassic: zero token");
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
        owner = msg.sender;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
        return rewardPerTokenStored + (elapsed * rewardRate * PRECISION) / _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        uint256 owedPerToken = rewardPerToken() - userRewardPerTokenPaid[account];
        return (_balances[account] * owedPerToken) / PRECISION + rewards[account];
    }

    function stake(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "StakingRewardsClassic: zero stake");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        _pullToken(stakingToken, msg.sender, amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, "StakingRewardsClassic: zero withdraw");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        _pushToken(stakingToken, msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            _pushToken(rewardsToken, msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /// @notice Owner funds a new reward period. Unspent rewards from the
    ///         previous period roll into the new one.
    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / REWARD_DURATION;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (reward + leftover) / REWARD_DURATION;
        }
        require(rewardRate > 0, "StakingRewardsClassic: reward too small");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARD_DURATION;

        _pullToken(rewardsToken, msg.sender, reward);
        emit RewardNotified(reward, rewardRate, periodFinish);
    }

    function _pullToken(IERC20 token, address from, uint256 amount) private {
        require(token.transferFrom(from, address(this), amount), "StakingRewardsClassic: transferFrom");
    }

    function _pushToken(IERC20 token, address to, uint256 amount) private {
        require(token.transfer(to, amount), "StakingRewardsClassic: transfer");
    }
}
