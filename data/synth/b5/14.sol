// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ---------------------------------------------------------------------------
// Inline SafeMath (2021 vintage)
// ---------------------------------------------------------------------------
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
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ===========================================================================
// BoostFarm - each staker's reward is multiplied by a boost factor read from
// a vote-escrow style balance. Boost is capped; it never exceeds 2.5x.
// ===========================================================================
contract BoostFarm {
    using SafeMath for uint256;

    struct StakeInfo {
        uint256 amount;
        uint256 weight;
        uint256 weightedDebt;
        uint256 owed;
    }

    uint256 private constant PRECISION = 1e12;
    uint256 private constant BOOST_CAP_BPS = 25000;
    uint256 private constant BPS = 10000;

    IERC20 public stakeToken;
    IERC20 public rewardToken;
    IERC20 public veToken;
    address public governance;
    uint256 public rewardPerSecond;
    uint256 public lastBump;
    uint256 public rewardIndex;
    uint256 public weightedTotal;

    mapping(address => uint256) public veBalance;
    mapping(address => StakeInfo) public stakes;

    event BoostedStake(address indexed user, uint256 amount, uint256 weight);
    event BoostedUnstake(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _stake, IERC20 _reward, IERC20 _ve, uint256 _rewardPerSecond) {
        stakeToken = _stake;
        rewardToken = _reward;
        veToken = _ve;
        rewardPerSecond = _rewardPerSecond;
        lastBump = block.timestamp;
        governance = msg.sender;
    }

    // Boost in basis points: 10000 (1x) up to BOOST_CAP_BPS (2.5x).
    function boostOf(address _user, uint256 _amount) public view returns (uint256) {
        uint256 base = BPS;
        uint256 extra = veBalance[_user].mul(BPS).div(_amount.add(1)).div(2);
        uint256 boost = base.add(extra);
        return boost > BOOST_CAP_BPS ? BOOST_CAP_BPS : boost;
    }

    // Settlement helper: advances the reward index and credits the account.
    function _bumpIndex(address _user) internal {
        uint256 dt = block.timestamp.sub(lastBump);
        if (dt > 0 && weightedTotal > 0) {
            rewardIndex = rewardIndex.add(dt.mul(rewardPerSecond).mul(PRECISION).div(weightedTotal));
        }
        lastBump = block.timestamp;
        if (_user != address(0)) {
            StakeInfo storage s = stakes[_user];
            s.owed = s.owed.add(s.weight.mul(rewardIndex).div(PRECISION).sub(s.weightedDebt));
            s.weightedDebt = s.weight.mul(rewardIndex).div(PRECISION);
        }
    }

    // Recomputes the account's boosted weight after its amount changed.
    function _refreshWeight(address _user) internal {
        StakeInfo storage s = stakes[_user];
        uint256 fresh = s.amount.mul(boostOf(_user, s.amount)).div(BPS);
        weightedTotal = weightedTotal.sub(s.weight).add(fresh);
        s.weight = fresh;
        s.weightedDebt = fresh.mul(rewardIndex).div(PRECISION);
    }

    function boostAndStake(uint256 _amount) external {
        require(_amount > 0, "BoostFarm: zero");
        _bumpIndex(msg.sender);
        StakeInfo storage s = stakes[msg.sender];
        s.amount = s.amount.add(_amount);
        _refreshWeight(msg.sender);
        require(stakeToken.transferFrom(msg.sender, address(this), _amount), "BoostFarm: in");
        emit BoostedStake(msg.sender, _amount, s.weight);
    }

    function unboost(uint256 _amount) external {
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount >= _amount, "BoostFarm: short");
        _bumpIndex(msg.sender);
        s.amount = s.amount.sub(_amount);
        _refreshWeight(msg.sender);
        require(stakeToken.transfer(msg.sender, _amount), "BoostFarm: out");
        emit BoostedUnstake(msg.sender, _amount);
    }

    function claimBoosted() external {
        _bumpIndex(msg.sender);
        StakeInfo storage s = stakes[msg.sender];
        uint256 owed = s.owed;
        s.owed = 0;
        if (owed > 0) {
            require(rewardToken.transfer(msg.sender, owed), "BoostFarm: reward");
            emit Claimed(msg.sender, owed);
        }
    }
}
