// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// File: contracts/libs/SafeMath.sol
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: add overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: sub overflow");
        return a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: mul overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: div by zero");
        return a / b;
    }
}

// File: contracts/interfaces/IERC20.sol
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

//--------------------------------------------------------------------------
// BakeryPools - multi-pool bakery with a deposit fee skimmed to the treasury
//--------------------------------------------------------------------------
contract BakeryPools {
    using SafeMath for uint256;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accLoafPerShare;
        uint16 depositFeeBP;
    }

    uint256 private constant ACC_PREC = 1e12;
    uint16 public constant MAX_FEE_BP = 400;

    IERC20 public loaf;
    address public owner;
    address public treasury;
    uint256 public loafPerSecond;
    uint256 public totalAllocPoint;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "BakeryPools: not owner");
        _;
    }

    constructor(IERC20 _loaf, address _treasury, uint256 _loafPerSecond) {
        loaf = _loaf;
        treasury = _treasury;
        loafPerSecond = _loafPerSecond;
        owner = msg.sender;
    }

    function addPool(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP) external onlyOwner {
        require(_depositFeeBP <= MAX_FEE_BP, "BakeryPools: fee too high");
        massUpdatePools();
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: block.timestamp,
            accLoafPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    function massUpdatePools() public {
        for (uint256 pid = 0; pid < poolInfo.length; pid++) {
            settlePool(pid);
        }
    }

    // Settlement helper: advances the pool's reward index to the present.
    function settlePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 supply = pool.lpToken.balanceOf(address(this));
        if (supply == 0 || totalAllocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp.sub(pool.lastRewardTime);
        uint256 minted = elapsed.mul(loafPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accLoafPerShare = pool.accLoafPerShare.add(minted.mul(ACC_PREC).div(supply));
        pool.lastRewardTime = block.timestamp;
    }

    function deposit(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        settlePool(_pid);
        uint256 owed = 0;
        if (user.amount > 0) {
            owed = user.amount.mul(pool.accLoafPerShare).div(ACC_PREC).sub(user.rewardDebt);
        }
        uint256 fee = _amount.mul(pool.depositFeeBP).div(10000);
        uint256 credited = _amount.sub(fee);
        user.amount = user.amount.add(credited);
        user.rewardDebt = user.amount.mul(pool.accLoafPerShare).div(ACC_PREC);

        require(pool.lpToken.transferFrom(msg.sender, address(this), _amount), "BakeryPools: transfer in");
        if (fee > 0) {
            require(pool.lpToken.transfer(treasury, fee), "BakeryPools: fee transfer");
        }
        if (owed > 0) {
            require(loaf.transfer(msg.sender, owed), "BakeryPools: loaf transfer");
            emit Harvest(msg.sender, _pid, owed);
        }
        emit Deposit(msg.sender, _pid, credited);
    }

    function withdraw(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "BakeryPools: insufficient");
        settlePool(_pid);
        uint256 owed = user.amount.mul(pool.accLoafPerShare).div(ACC_PREC).sub(user.rewardDebt);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accLoafPerShare).div(ACC_PREC);

        if (owed > 0) {
            require(loaf.transfer(msg.sender, owed), "BakeryPools: loaf transfer");
            emit Harvest(msg.sender, _pid, owed);
        }
        if (_amount > 0) {
            require(pool.lpToken.transfer(msg.sender, _amount), "BakeryPools: lp transfer");
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
}
