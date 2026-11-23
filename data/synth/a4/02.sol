// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title LockBoostStaking
/// @notice Stakers choose a lock duration; longer locks multiply the weight used for
///         reward distribution. Rewards are tracked with a global per-weight index.
/// @dev Rewards are funded by transferring rewardToken directly to this contract.
contract LockBoostStaking {
    error InvalidDuration(uint256 duration);
    error StillLocked(uint256 unlockAt);
    error AmountExceedsStake(uint256 requested, uint256 staked);
    error ZeroAmount();
    error Unauthorized();
    error TransferFailed();

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MIN_LOCK = 30 days;
    uint256 public constant MAX_LOCK = 365 days;
    uint256 public constant BASE_MULTIPLIER = 1e4;
    uint256 public constant MAX_BOOST = 3e4;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    address public immutable governor;

    uint256 public rewardRate;
    uint256 public rewardIndex;
    uint256 public lastIndexUpdate;
    uint256 public totalWeight;

    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public weightOf;
    mapping(address => uint256) public unlockAt;
    mapping(address => uint256) public rewardsOwed;
    mapping(address => uint256) private _indexPaid;

    event Locked(address indexed user, uint256 amount, uint256 duration, uint256 weight);
    event Unlocked(address indexed user, uint256 amount, uint256 weightRemoved);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardRateSet(uint256 rate);

    constructor(IERC20 _stakingToken, IERC20 _rewardToken) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        governor = msg.sender;
        lastIndexUpdate = block.timestamp;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorized();
        _;
    }

    function setRewardRate(uint256 rate) external onlyGovernor {
        _updateIndex();
        rewardRate = rate;
        emit RewardRateSet(rate);
    }

    function multiplierFor(uint256 duration) public pure returns (uint256) {
        return BASE_MULTIPLIER + MAX_BOOST * duration / MAX_LOCK;
    }

    function lock(uint256 amount, uint256 duration) external {
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_LOCK || duration > MAX_LOCK) revert InvalidDuration(duration);

        _collect(msg.sender);

        uint256 weight = amount * multiplierFor(duration) / BASE_MULTIPLIER;
        uint256 newUnlock = block.timestamp + duration;
        if (newUnlock > unlockAt[msg.sender]) unlockAt[msg.sender] = newUnlock;

        stakedOf[msg.sender] += amount;
        weightOf[msg.sender] += weight;
        totalWeight += weight;

        if (!stakingToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Locked(msg.sender, amount, duration, weight);
    }

    function unlock(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = stakedOf[msg.sender];
        if (amount > staked) revert AmountExceedsStake(amount, staked);
        if (block.timestamp < unlockAt[msg.sender]) revert StillLocked(unlockAt[msg.sender]);

        _collect(msg.sender);

        uint256 weightOut = weightOf[msg.sender] * amount / staked;
        stakedOf[msg.sender] = staked - amount;
        weightOf[msg.sender] -= weightOut;
        totalWeight -= weightOut;

        if (!stakingToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Unlocked(msg.sender, amount, weightOut);
    }

    function claimRewards() external returns (uint256 amount) {
        _collect(msg.sender);
        amount = rewardsOwed[msg.sender];
        if (amount == 0) return 0;

        rewardsOwed[msg.sender] = 0;
        if (!rewardToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit RewardsClaimed(msg.sender, amount);
    }

    function _updateIndex() internal {
        uint256 elapsed = block.timestamp - lastIndexUpdate;
        if (elapsed > 0 && totalWeight > 0) {
            rewardIndex += rewardRate * elapsed * PRECISION / totalWeight;
        }
        lastIndexUpdate = block.timestamp;
    }

    function _collect(address user) internal {
        _updateIndex();
        uint256 delta = rewardIndex - _indexPaid[user];
        rewardsOwed[user] += weightOf[user] * delta / PRECISION;
        _indexPaid[user] = rewardIndex;
    }
}
