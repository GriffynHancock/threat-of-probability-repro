// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title LockBoostPool
/// @notice Staking where a lock commitment and a referral raise a user's
///         effective balance above their raw balance.
///         effective = raw * (1 + bonus) / PRECISION, bonus capped at MAX_BONUS.
contract LockBoostPool {
    error StillLocked(uint256 unlocksAt);
    error NothingToClaim();
    error NotAdmin();
    error BadReferrer();

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_BONUS = 1e18;
    uint256 public constant REFERRAL_BONUS = 0.05e18;

    IERC20 public immutable token;
    IERC20 public immutable rewardToken;
    address public admin;

    uint256 public rewardPerSecond;
    uint256 public lastTouch;
    uint256 public accPerEffective; // scaled by PRECISION
    uint256 public totalEffective;

    mapping(address => uint256) public rawBalance;
    mapping(address => uint256) public effectiveBalance;
    mapping(address => uint256) public lockedUntil;
    mapping(address => uint256) public lockBonus;
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public accountedAcc;
    mapping(address => uint256) public unclaimed;

    event Deposited(address indexed user, uint256 amount, uint256 lockSeconds);
    event Withdrawn(address indexed user, uint256 amount);
    event ReferrerSet(address indexed user, address indexed referrer);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _token, IERC20 _rewardToken, uint256 _rewardPerSecond) {
        token = _token;
        rewardToken = _rewardToken;
        admin = msg.sender;
        rewardPerSecond = _rewardPerSecond;
        lastTouch = block.timestamp;
    }

    function deposit(uint256 amount, uint256 lockSeconds) external {
        _touchAccount(msg.sender);
        require(amount > 0, "zero amount");
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");

        rawBalance[msg.sender] += amount;
        uint256 unlock = block.timestamp + lockSeconds;
        if (unlock > lockedUntil[msg.sender]) lockedUntil[msg.sender] = unlock;

        uint256 tier = _tierBonus(lockSeconds);
        if (tier > lockBonus[msg.sender]) lockBonus[msg.sender] = tier;

        _refreshEffective(msg.sender);
        emit Deposited(msg.sender, amount, lockSeconds);
    }

    /// @notice One-time referral link. Gives the referee the referral bonus.
    function setReferrer(address ref) external {
        if (ref == address(0) || ref == msg.sender || referrerOf[msg.sender] != address(0)) {
            revert BadReferrer();
        }
        _touchAccount(msg.sender);
        referrerOf[msg.sender] = ref;
        _refreshEffective(msg.sender);
        emit ReferrerSet(msg.sender, ref);
    }

    function withdraw(uint256 amount) external {
        if (block.timestamp < lockedUntil[msg.sender]) revert StillLocked(lockedUntil[msg.sender]);
        _touchAccount(msg.sender);
        require(amount > 0 && amount <= rawBalance[msg.sender], "bad amount");

        rawBalance[msg.sender] -= amount;
        _refreshEffective(msg.sender);
        require(token.transfer(msg.sender, amount), "send failed");
        emit Withdrawn(msg.sender, amount);
    }

    function claim() external {
        _touchAccount(msg.sender);
        uint256 amt = unclaimed[msg.sender];
        if (amt == 0) revert NothingToClaim();
        unclaimed[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amt), "reward send failed");
        emit Claimed(msg.sender, amt);
    }

    function setRewardPerSecond(uint256 r) external {
        if (msg.sender != admin) revert NotAdmin();
        _advance();
        rewardPerSecond = r;
    }

    /// @dev Settlement helper: accrue the global index, then credit the user's
    ///      share at their existing effective balance. Callers invoke this
    ///      before raw or effective balances change.
    function _touchAccount(address who) internal {
        _advance();
        uint256 owed = effectiveBalance[who] * (accPerEffective - accountedAcc[who]) / PRECISION;
        unclaimed[who] += owed;
        accountedAcc[who] = accPerEffective;
    }

    function _advance() internal {
        uint256 dt = block.timestamp - lastTouch;
        lastTouch = block.timestamp;
        if (dt > 0 && totalEffective > 0) {
            accPerEffective += rewardPerSecond * dt * PRECISION / totalEffective;
        }
    }

    function _refreshEffective(address who) internal {
        uint256 bonus = lockBonus[who];
        if (referrerOf[who] != address(0)) bonus += REFERRAL_BONUS;
        if (bonus > MAX_BONUS) bonus = MAX_BONUS;

        uint256 next = rawBalance[who] * (PRECISION + bonus) / PRECISION;
        totalEffective = totalEffective - effectiveBalance[who] + next;
        effectiveBalance[who] = next;
    }

    function _tierBonus(uint256 lockSeconds) internal pure returns (uint256) {
        if (lockSeconds >= 365 days) return 1e18;
        if (lockSeconds >= 90 days) return 0.6e18;
        if (lockSeconds >= 30 days) return 0.25e18;
        return 0;
    }
}
