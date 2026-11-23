// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/// @notice Minimal token surface used by the pool.
interface IToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Called by the pool after it has transferred a user's stake to the
///         migrator. The migrator is responsible for crediting that user on the
///         successor pool.
interface IPoolMigrator {
    function onMigrate(address account, uint256 amount) external returns (bool);
}

/// @title MigratablePool
/// @notice Single-token staking with a timelocked, staged migrator.
///
/// Upgrade path:
///   1. owner calls `stageMigrator(m)`; this records `m` and starts a timelock.
///   2. after `TIMELOCK` seconds, anyone may call `activateMigrator()`.
///   3. users may then call `migrate()` to move their own stake to `m`.
///
/// Users who never migrate are unaffected; withdraw and claim keep working.
contract MigratablePool {
    /// Delay between staging and activation of a migrator.
    uint256 public constant TIMELOCK = 2 days;
    /// Fixed-point scale for the reward accumulator.
    uint256 public constant PRECISION = 1e18;

    struct Account {
        uint256 balance;
        uint256 rewardDebt;
        uint256 accrued;
    }

    IToken public immutable stakeToken;
    IToken public immutable rewardToken;
    address public owner;

    address public migrator;
    address public pendingMigrator;
    uint256 public migratorReadyAt;

    uint256 public rewardPerSecond;
    uint256 public lastRewardTime;
    uint256 public accRewardPerToken;
    uint256 public totalStaked;

    mapping(address => Account) public accounts;

    event MigratorStaged(address indexed migrator, uint256 readyAt);
    event MigratorActivated(address indexed migrator);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Migrated(address indexed account, address indexed to, uint256 amount);
    event Claimed(address indexed account, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "MigratablePool: not owner");
        _;
    }

    constructor(IToken _stake, IToken _reward, uint256 _rewardPerSecond) {
        stakeToken = _stake;
        rewardToken = _reward;
        owner = msg.sender;
        rewardPerSecond = _rewardPerSecond;
        lastRewardTime = block.timestamp;
    }

    // ---------------------------------------------------------------
    // Migrator lifecycle
    // ---------------------------------------------------------------

    function stageMigrator(address m) external onlyOwner {
        require(m != address(0), "MigratablePool: zero migrator");
        pendingMigrator = m;
        migratorReadyAt = block.timestamp + TIMELOCK;
        emit MigratorStaged(m, migratorReadyAt);
    }

    function activateMigrator() external {
        require(pendingMigrator != address(0), "MigratablePool: nothing staged");
        require(block.timestamp >= migratorReadyAt, "MigratablePool: timelock");
        migrator = pendingMigrator;
        pendingMigrator = address(0);
        emit MigratorActivated(migrator);
    }

    // ---------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------

    /// @notice Stake `amount`. Settles accrued rewards at the current balance
    ///         before the balance is increased.
    function deposit(uint256 amount) external {
        _updateAccount(msg.sender);
        require(amount > 0, "MigratablePool: zero");
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "MigratablePool: pull");

        accounts[msg.sender].balance += amount;
        totalStaked += amount;
        _resetDebt(msg.sender);
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        _updateAccount(msg.sender);
        Account storage a = accounts[msg.sender];
        require(amount > 0 && amount <= a.balance, "MigratablePool: bad amount");

        a.balance -= amount;
        totalStaked -= amount;
        _resetDebt(msg.sender);
        require(stakeToken.transfer(msg.sender, amount), "MigratablePool: send");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Move the caller's entire stake to the active migrator.
    function migrate() external {
        address m = migrator;
        require(m != address(0), "MigratablePool: no migrator");

        _updateAccount(msg.sender);
        uint256 amount = accounts[msg.sender].balance;
        require(amount > 0, "MigratablePool: nothing to migrate");

        accounts[msg.sender].balance = 0;
        totalStaked -= amount;
        _resetDebt(msg.sender);

        require(stakeToken.transfer(m, amount), "MigratablePool: send to migrator");
        require(IPoolMigrator(m).onMigrate(msg.sender, amount), "MigratablePool: migrator rejected");
        emit Migrated(msg.sender, m, amount);
    }

    function claim() external {
        _updateAccount(msg.sender);
        uint256 amt = accounts[msg.sender].accrued;
        require(amt > 0, "MigratablePool: nothing accrued");
        accounts[msg.sender].accrued = 0;
        require(rewardToken.transfer(msg.sender, amt), "MigratablePool: reward send");
        emit Claimed(msg.sender, amt);
    }

    // ---------------------------------------------------------------
    // Internal accounting
    // ---------------------------------------------------------------

    /// @dev Brings the global accumulator up to date, then credits the account
    ///      with what it has earned against its CURRENT balance. This is the
    ///      settlement step; it is always the first thing a balance-changing
    ///      function does.
    function _updateAccount(address who) internal {
        _advancePool();
        Account storage a = accounts[who];
        uint256 earned = a.balance * accRewardPerToken / PRECISION;
        a.accrued += earned - a.rewardDebt;
        a.rewardDebt = earned;
    }

    /// @dev After a balance change, re-base the debt so the next settlement
    ///      does not double-count.
    function _resetDebt(address who) internal {
        Account storage a = accounts[who];
        a.rewardDebt = a.balance * accRewardPerToken / PRECISION;
    }

    function _advancePool() internal {
        uint256 dt = block.timestamp - lastRewardTime;
        lastRewardTime = block.timestamp;
        if (dt == 0 || totalStaked == 0) return;
        accRewardPerToken += rewardPerSecond * dt * PRECISION / totalStaked;
    }
}
