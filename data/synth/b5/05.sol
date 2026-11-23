// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
pragma experimental ABIEncoderV2;

// File: contracts/IMigratorChef.sol
interface IMigratorChef {
    function migrate(address lpToken) external returns (address);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ============================================================================
// MigrationFarm - v1 pools that can be moved onto a v2 LP token by a migrator
// ============================================================================
contract MigrationFarm {
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardTimestamp;
        uint256 accRewardPerShare;
    }

    uint256 internal constant SCALE = 1e12;

    address public governor;
    IMigratorChef public migrator;
    IERC20 public reward;
    uint256 public rewardPerSecond;
    uint256 public totalAllocPoint;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    event Migrated(uint256 indexed pid, address indexed oldLp, address indexed newLp);
    event MigrateIn(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    modifier onlyGovernor() {
        require(msg.sender == governor, "MigrationFarm: not governor");
        _;
    }

    constructor(IERC20 _reward, uint256 _rewardPerSecond) {
        reward = _reward;
        rewardPerSecond = _rewardPerSecond;
        governor = msg.sender;
    }

    function setMigrator(IMigratorChef _migrator) external onlyGovernor {
        migrator = _migrator;
    }

    function addPool(uint256 _alloc, IERC20 _lp) external onlyGovernor {
        totalAllocPoint += _alloc;
        poolInfo.push(PoolInfo(_lp, _alloc, block.timestamp, 0));
    }

    // Moves a pool onto the LP token the migrator returns for it.
    function migrate(uint256 _pid) external onlyGovernor {
        require(address(migrator) != address(0), "MigrationFarm: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 oldLp = pool.lpToken;
        uint256 bal = oldLp.balanceOf(address(this));
        address newLp = migrator.migrate(address(oldLp));
        require(IERC20(newLp).balanceOf(address(this)) == bal, "MigrationFarm: balance mismatch");
        pool.lpToken = IERC20(newLp);
        emit Migrated(_pid, address(oldLp), newLp);
    }

    // Settlement helper: rolls the reward index forward for one pool.
    function _rollPoolEpoch(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTimestamp) {
            return;
        }
        uint256 supply = pool.lpToken.balanceOf(address(this));
        if (supply == 0) {
            pool.lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 secs = block.timestamp - pool.lastRewardTimestamp;
        uint256 r = secs * rewardPerSecond * pool.allocPoint / totalAllocPoint;
        pool.accRewardPerShare += r * SCALE / supply;
        pool.lastRewardTimestamp = block.timestamp;
    }

    // Accepts LP that the migrator has already moved into this contract.
    function migrateIn(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        _rollPoolEpoch(_pid);
        uint256 pending = 0;
        if (user.amount > 0) {
            pending = user.amount * pool.accRewardPerShare / SCALE - user.rewardDebt;
        }
        user.amount += _amount;
        user.rewardDebt = user.amount * pool.accRewardPerShare / SCALE;
        if (pending > 0) {
            require(reward.transfer(msg.sender, pending), "MigrationFarm: reward");
        }
        if (_amount > 0) {
            require(pool.lpToken.transferFrom(msg.sender, address(this), _amount), "MigrationFarm: lp");
        }
        emit MigrateIn(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "MigrationFarm: too much");
        _rollPoolEpoch(_pid);
        uint256 pending = user.amount * pool.accRewardPerShare / SCALE - user.rewardDebt;
        user.amount -= _amount;
        user.rewardDebt = user.amount * pool.accRewardPerShare / SCALE;
        if (pending > 0) {
            require(reward.transfer(msg.sender, pending), "MigrationFarm: reward");
        }
        require(pool.lpToken.transfer(msg.sender, _amount), "MigrationFarm: lp out");
        emit Withdraw(msg.sender, _pid, _amount);
    }
}
