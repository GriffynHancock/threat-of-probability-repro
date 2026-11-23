// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
pragma experimental ABIEncoderV2;

// File: contracts/interfaces/IERC20.sol
interface IERC20 {
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
}

//------------------------------------------------------------------------------
// ChefGarden v1 - multi-pool farm, MasterChef-era house style
//------------------------------------------------------------------------------
contract ChefGarden {
    struct UserInfo {
        uint amount;
        uint rewardDebt;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint allocPoint;
        uint lastRewardBlock;
        uint accRewardPerShare;
    }

    uint constant ACC_PRECISION = 1e12;

    IERC20 public rewardToken;
    address public owner;
    uint public rewardPerBlock;
    uint public totalAllocPoint;
    uint public startBlock;

    PoolInfo[] public poolInfo;
    mapping(uint => mapping(address => UserInfo)) public userInfo;

    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);
    event Harvest(address indexed user, uint indexed pid, uint amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "ChefGarden: caller is not the owner");
        _;
    }

    constructor(IERC20 _rewardToken, uint _rewardPerBlock, uint _startBlock) {
        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        owner = msg.sender;
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    // ---------------------------------------------------------------
    // Pool admin
    // ---------------------------------------------------------------
    function add(uint _allocPoint, IERC20 _lpToken) public onlyOwner {
        massUpdatePools();
        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRewardPerShare: 0
        }));
    }

    function set(uint _pid, uint _allocPoint) public onlyOwner {
        massUpdatePools();
        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // ---------------------------------------------------------------
    // Accrual
    // ---------------------------------------------------------------
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint multiplier = block.number - pool.lastRewardBlock;
        uint reward = multiplier * rewardPerBlock * pool.allocPoint / totalAllocPoint;
        pool.accRewardPerShare += reward * ACC_PRECISION / lpSupply;
        pool.lastRewardBlock = block.number;
    }

    function pendingReward(uint _pid, address _user) external view returns (uint) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint acc = pool.accRewardPerShare;
        uint lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint multiplier = block.number - pool.lastRewardBlock;
            uint reward = multiplier * rewardPerBlock * pool.allocPoint / totalAllocPoint;
            acc += reward * ACC_PRECISION / lpSupply;
        }
        return user.amount * acc / ACC_PRECISION - user.rewardDebt;
    }

    // ---------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------
    function deposit(uint _pid, uint _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint pending = 0;
        if (user.amount > 0) {
            pending = user.amount * pool.accRewardPerShare / ACC_PRECISION - user.rewardDebt;
        }
        user.amount += _amount;
        user.rewardDebt = user.amount * pool.accRewardPerShare / ACC_PRECISION;
        if (pending > 0) {
            require(rewardToken.transfer(msg.sender, pending), "ChefGarden: reward transfer failed");
            emit Harvest(msg.sender, _pid, pending);
        }
        if (_amount > 0) {
            require(pool.lpToken.transferFrom(msg.sender, address(this), _amount), "ChefGarden: deposit failed");
        }
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint _pid, uint _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "ChefGarden: withdraw too much");
        updatePool(_pid);
        uint pending = user.amount * pool.accRewardPerShare / ACC_PRECISION - user.rewardDebt;
        user.amount -= _amount;
        user.rewardDebt = user.amount * pool.accRewardPerShare / ACC_PRECISION;
        if (pending > 0) {
            require(rewardToken.transfer(msg.sender, pending), "ChefGarden: reward transfer failed");
            emit Harvest(msg.sender, _pid, pending);
        }
        if (_amount > 0) {
            require(pool.lpToken.transfer(msg.sender, _amount), "ChefGarden: withdraw failed");
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function emergencyWithdraw(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        require(pool.lpToken.transfer(msg.sender, amount), "ChefGarden: emergency failed");
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "ChefGarden: zero owner");
        owner = _newOwner;
    }
}
