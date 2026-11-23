// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Multi-pool registry. Each pool has its own reward accumulator and
/// users carry a reward-debt per pool, in the style of a masterchef farm.
contract PoolRegistryFarm {
    uint256 private constant ACC_PRECISION = 1e12;

    struct PoolInfo {
        IERC20 stakeToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accRewardPerShare;
        uint256 totalStaked;
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    IERC20 public immutable rewardToken;
    address public immutable operator;
    uint256 public rewardPerSecond;
    uint256 public totalAllocPoint;

    PoolInfo[] public pools;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => uint256) public pendingReward;

    event PoolAdded(uint256 indexed pid, address token, uint256 allocPoint);
    event Staked(uint256 indexed pid, address indexed user, uint256 amount);
    event Unstaked(uint256 indexed pid, address indexed user, uint256 amount);
    event Harvested(uint256 indexed pid, address indexed user, uint256 amount);

    constructor(IERC20 _reward, uint256 _rewardPerSecond) {
        rewardToken = _reward;
        rewardPerSecond = _rewardPerSecond;
        operator = msg.sender;
    }

    function addPool(IERC20 token, uint256 allocPoint) external {
        require(msg.sender == operator, "not operator");
        totalAllocPoint += allocPoint;
        pools.push(PoolInfo({
            stakeToken: token,
            allocPoint: allocPoint,
            lastRewardTime: block.timestamp,
            accRewardPerShare: 0,
            totalStaked: 0
        }));
        emit PoolAdded(pools.length - 1, address(token), allocPoint);
    }

    function stakeInPool(uint256 pid, uint256 amount) external {
        require(pid < pools.length, "no such pool");
        require(amount > 0, "zero amount");
        _harvestPool(pid, msg.sender);
        UserInfo storage u = userInfo[pid][msg.sender];
        PoolInfo storage pool = pools[pid];
        u.amount += amount;
        pool.totalStaked += amount;
        u.rewardDebt = u.amount * pool.accRewardPerShare / ACC_PRECISION;
        require(pool.stakeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Staked(pid, msg.sender, amount);
    }

    function unstakeFromPool(uint256 pid, uint256 amount) external {
        require(pid < pools.length, "no such pool");
        UserInfo storage u = userInfo[pid][msg.sender];
        require(u.amount >= amount, "insufficient stake");
        _harvestPool(pid, msg.sender);
        PoolInfo storage pool = pools[pid];
        u.amount -= amount;
        pool.totalStaked -= amount;
        u.rewardDebt = u.amount * pool.accRewardPerShare / ACC_PRECISION;
        require(pool.stakeToken.transfer(msg.sender, amount), "transfer failed");
        emit Unstaked(pid, msg.sender, amount);
    }

    function harvest(uint256 pid) external {
        require(pid < pools.length, "no such pool");
        _harvestPool(pid, msg.sender);
        uint256 amount = pendingReward[msg.sender];
        if (amount == 0) return;
        pendingReward[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amount), "transfer failed");
        emit Harvested(pid, msg.sender, amount);
    }

    /// @dev Advances the pool accumulator, then books the user's pending reward
    /// computed against the pre-change debt.
    function _harvestPool(uint256 pid, address user) internal {
        PoolInfo storage pool = pools[pid];
        if (block.timestamp > pool.lastRewardTime) {
            if (pool.totalStaked > 0 && totalAllocPoint > 0) {
                uint256 elapsed = block.timestamp - pool.lastRewardTime;
                uint256 reward = elapsed * rewardPerSecond * pool.allocPoint / totalAllocPoint;
                pool.accRewardPerShare += reward * ACC_PRECISION / pool.totalStaked;
            }
            pool.lastRewardTime = block.timestamp;
        }
        UserInfo storage u = userInfo[pid][user];
        if (u.amount > 0) {
            pendingReward[user] += u.amount * pool.accRewardPerShare / ACC_PRECISION - u.rewardDebt;
        }
    }
}
