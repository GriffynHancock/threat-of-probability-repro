// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Inline SafeMath, as shipped in the 2019-2020 forks
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

//==============================================================================
//  SingleFarmPlanter  -  one staking token, one reward token, Synthetix-style
//==============================================================================
contract SingleFarmPlanter {
    using SafeMath for uint256;

    struct Staker {
        uint256 amount;
        uint256 rewardPaid;
        uint256 earned;
    }

    uint256 public constant PRECISION = 1e18;

    IERC20 public stakingToken;
    IERC20 public rewardToken;
    address public admin;

    uint256 public rewardRate;
    uint256 public rewardsDuration = 7 days;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored;
    uint256 public totalStaked;

    mapping(address => Staker) public stakers;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 reward);
    event RewardNotified(uint256 reward, uint256 rate);

    modifier onlyAdmin() {
        require(msg.sender == admin, "SingleFarmPlanter: not admin");
        _;
    }

    constructor(IERC20 _stakingToken, IERC20 _rewardToken) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        admin = msg.sender;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored.add(
            lastTimeRewardApplicable().sub(lastUpdate).mul(rewardRate).mul(PRECISION).div(totalStaked)
        );
    }

    function earnedOf(address account) public view returns (uint256) {
        Staker storage s = stakers[account];
        return s.amount.mul(rewardPerToken().sub(s.rewardPaid)).div(PRECISION).add(s.earned);
    }

    // Settlement helper: brings the global index and this account's earnings up to date.
    function _accrue(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdate = lastTimeRewardApplicable();
        if (account != address(0)) {
            Staker storage s = stakers[account];
            s.earned = earnedOf(account);
            s.rewardPaid = rewardPerTokenStored;
        }
    }

    function notifyRewardAmount(uint256 reward) external onlyAdmin {
        _accrue(address(0));
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }
        require(rewardRate > 0, "SingleFarmPlanter: rate is zero");
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardNotified(reward, rewardRate);
    }

    function stake(uint256 _amount) external {
        require(_amount > 0, "SingleFarmPlanter: cannot stake zero");
        _accrue(msg.sender);
        Staker storage s = stakers[msg.sender];
        s.amount = s.amount.add(_amount);
        totalStaked = totalStaked.add(_amount);
        require(stakingToken.transferFrom(msg.sender, address(this), _amount), "SingleFarmPlanter: transfer failed");
        emit Staked(msg.sender, _amount);
    }

    function unstake(uint256 _amount) public {
        require(_amount > 0, "SingleFarmPlanter: cannot unstake zero");
        _accrue(msg.sender);
        Staker storage s = stakers[msg.sender];
        s.amount = s.amount.sub(_amount);
        totalStaked = totalStaked.sub(_amount);
        require(stakingToken.transfer(msg.sender, _amount), "SingleFarmPlanter: transfer failed");
        emit Unstaked(msg.sender, _amount);
    }

    function getReward() public {
        _accrue(msg.sender);
        Staker storage s = stakers[msg.sender];
        uint256 reward = s.earned;
        if (reward > 0) {
            s.earned = 0;
            require(rewardToken.transfer(msg.sender, reward), "SingleFarmPlanter: reward failed");
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        unstake(stakers[msg.sender].amount);
        getReward();
    }
}
