// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ---------------------------------------------------------------------------
// Inline SafeMath
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

// ============================================================================
// VestedFarm - deposits earn a reward stream. Earned rewards land in a pending
// bucket that unlocks linearly over VEST_LENGTH from the last unlock point.
// ============================================================================
contract VestedFarm {
    using SafeMath for uint256;

    struct Vest {
        uint256 deposit;
        uint256 rewardDebt;
        uint256 pending;
        uint256 unlockFrom;
    }

    uint256 private constant PREC = 1e18;
    uint256 public constant VEST_LENGTH = 90 days;

    IERC20 public depositToken;
    IERC20 public rewardToken;
    address public owner;
    uint256 public rewardPerSecond;
    uint256 public lastAccrual;
    uint256 public accPerToken;
    uint256 public totalDeposits;

    mapping(address => Vest) public vests;

    event Deposited(address indexed who, uint256 amount);
    event Withdrawn(address indexed who, uint256 amount);
    event VestedClaim(address indexed who, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "VestedFarm: owner only");
        _;
    }

    constructor(IERC20 _dep, IERC20 _rew, uint256 _rewardPerSecond) {
        depositToken = _dep;
        rewardToken = _rew;
        rewardPerSecond = _rewardPerSecond;
        lastAccrual = block.timestamp;
        owner = msg.sender;
    }

    // Settlement helper: advances the global index, then moves this account's
    // newly earned amount into its pending (unvesting) bucket.
    function _settleVesting(address _who) internal {
        if (block.timestamp > lastAccrual && totalDeposits > 0) {
            uint256 dt = block.timestamp.sub(lastAccrual);
            accPerToken = accPerToken.add(dt.mul(rewardPerSecond).mul(PREC).div(totalDeposits));
        }
        lastAccrual = block.timestamp;
        if (_who == address(0)) {
            return;
        }
        Vest storage v = vests[_who];
        uint256 earned = v.deposit.mul(accPerToken.sub(v.rewardDebt)).div(PREC);
        if (earned > 0 && v.pending == 0) {
            v.unlockFrom = block.timestamp;
        }
        v.pending = v.pending.add(earned);
        v.rewardDebt = accPerToken;
    }

    function _unlockedNow(address _who) internal view returns (uint256) {
        Vest storage v = vests[_who];
        uint256 elapsed = block.timestamp.sub(v.unlockFrom);
        if (elapsed >= VEST_LENGTH) return v.pending;
        return v.pending.mul(elapsed).div(VEST_LENGTH);
    }

    function depositVested(uint256 _amount) external {
        require(_amount > 0, "VestedFarm: zero");
        _settleVesting(msg.sender);
        Vest storage v = vests[msg.sender];
        v.deposit = v.deposit.add(_amount);
        totalDeposits = totalDeposits.add(_amount);
        v.rewardDebt = accPerToken;
        require(depositToken.transferFrom(msg.sender, address(this), _amount), "VestedFarm: in");
        emit Deposited(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external {
        Vest storage v = vests[msg.sender];
        require(v.deposit >= _amount, "VestedFarm: short");
        _settleVesting(msg.sender);
        v.deposit = v.deposit.sub(_amount);
        totalDeposits = totalDeposits.sub(_amount);
        v.rewardDebt = accPerToken;
        require(depositToken.transfer(msg.sender, _amount), "VestedFarm: out");
        emit Withdrawn(msg.sender, _amount);
    }

    function claimVested() external {
        _settleVesting(msg.sender);
        Vest storage v = vests[msg.sender];
        uint256 claimable = _unlockedNow(msg.sender);
        v.pending = v.pending.sub(claimable);
        v.unlockFrom = block.timestamp;
        if (claimable > 0) {
            require(rewardToken.transfer(msg.sender, claimable), "VestedFarm: reward");
            emit VestedClaim(msg.sender, claimable);
        }
    }

    function setRewardPerSecond(uint256 _rate) external onlyOwner {
        _settleVesting(address(0));
        rewardPerSecond = _rate;
    }
}
