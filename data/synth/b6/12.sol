// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Reward-per-token staking over a fixed emission period.
contract RewardPerTokenStaking {
    uint256 private constant SCALE = 1e18;
    uint256 public constant DURATION = 7 days;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    address public immutable governor;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 amount, uint256 rate);

    constructor(IERC20 _stakingToken, IERC20 _rewardToken) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        governor = msg.sender;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * SCALE) / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / SCALE
            + rewards[account];
    }

    function _updateRewardIndex(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function depositStake(uint256 amount) external {
        require(amount > 0, "zero");
        _updateRewardIndex(msg.sender);
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
        emit Staked(msg.sender, amount);
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function withdrawStake(uint256 amount) external {
        require(amount > 0, "zero");
        _updateRewardIndex(msg.sender);
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Withdrawn(msg.sender, amount);
        require(stakingToken.transfer(msg.sender, amount), "xfer");
    }

    function claimRewards() external returns (uint256 reward) {
        _updateRewardIndex(msg.sender);
        reward = rewards[msg.sender];
        require(reward > 0, "none");
        rewards[msg.sender] = 0;
        emit RewardPaid(msg.sender, reward);
        require(rewardToken.transfer(msg.sender, reward), "xfer");
    }

    function notifyRewardAmount(uint256 amount) external {
        require(msg.sender == governor, "not governor");
        _updateRewardIndex(address(0));
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / DURATION;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (amount + leftover) / DURATION;
        }
        require(rewardRate > 0, "rate");
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        emit RewardNotified(amount, rewardRate);
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "pull");
    }
}
