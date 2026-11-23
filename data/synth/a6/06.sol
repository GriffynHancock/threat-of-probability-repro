// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IRewardToken {
    function transfer(address recipient, uint256 value) external returns (bool);
}

contract PoolAllocationHub {
    uint256 internal constant P = 1e12;

    error BadInput();
    error UnknownPool(uint256 poolId);
    error NothingToPay();
    error TokenSendFailed();

    struct PoolInfo {
        uint128 ratePerSecond;
        uint64 lastTouched;
        uint256 accPerUnit;
        uint256 totalUnits;
    }

    event PoolRegistered(uint256 indexed poolId, uint128 ratePerSecond);
    event PoolRateSet(uint256 indexed poolId, uint128 ratePerSecond);
    event PoolTouched(uint256 indexed poolId, uint256 accPerUnit);
    event PoolPaid(uint256 indexed poolId, address indexed account, uint256 amount);

    IRewardToken public immutable rewardToken;
    address public immutable steward;

    PoolInfo[] private _pools;
    mapping(uint256 => mapping(address => uint256)) public unitsOf;
    mapping(uint256 => mapping(address => int256)) public debtOf;

    constructor(
        IRewardToken rewardToken_,
        uint128[] memory rates,
        uint256[] memory poolIds,
        address[] memory accounts,
        uint256[] memory units
    ) {
        if (poolIds.length != accounts.length || accounts.length != units.length) revert BadInput();
        rewardToken = rewardToken_;
        steward = msg.sender;

        for (uint256 i = 0; i < rates.length; i++) {
            _pools.push(PoolInfo({ratePerSecond: rates[i], lastTouched: uint64(block.timestamp), accPerUnit: 0, totalUnits: 0}));
            emit PoolRegistered(i, rates[i]);
        }

        // Allocations are fixed at deployment. There is no later write to unitsOf.
        for (uint256 i = 0; i < poolIds.length; i++) {
            if (poolIds[i] >= _pools.length) revert UnknownPool(poolIds[i]);
            unitsOf[poolIds[i]][accounts[i]] = units[i];
            _pools[poolIds[i]].totalUnits = _pools[poolIds[i]].totalUnits + units[i];
        }
    }

    function poolCount() external view returns (uint256) {
        return _pools.length;
    }

    /// Updates pool indices for a set of pools. Pays no one.
    function massTouch(uint256[] calldata poolIds) external {
        for (uint256 i = 0; i < poolIds.length; i++) {
            _advancePool(poolIds[i]);
        }
    }

    function setRate(uint256 poolId, uint128 next) external {
        require(msg.sender == steward, "steward");
        _advancePool(poolId);
        _pools[poolId].ratePerSecond = next;
        emit PoolRateSet(poolId, next);
    }

    /// Claims rewards from the listed pools for the caller in one transaction.
    function claimPools(uint256[] calldata poolIds) external returns (uint256 total) {
        for (uint256 i = 0; i < poolIds.length; i++) {
            uint256 pid = poolIds[i];
            uint256 got = _harvestPoolFor(pid, msg.sender);
            total = total + got;
            if (got > 0) emit PoolPaid(pid, msg.sender, got);
        }
        if (total == 0) revert NothingToPay();
        if (!rewardToken.transfer(msg.sender, total)) revert TokenSendFailed();
    }

    function pendingIn(uint256 poolId, address account) external view returns (uint256) {
        PoolInfo storage pool = _pools[poolId];
        uint256 acc = pool.accPerUnit;
        if (pool.totalUnits > 0 && block.timestamp > pool.lastTouched) {
            uint256 elapsed = block.timestamp - pool.lastTouched;
            acc = acc + (elapsed * pool.ratePerSecond * P) / pool.totalUnits;
        }
        int256 earned = int256((unitsOf[poolId][account] * acc) / P);
        return uint256(earned - debtOf[poolId][account]);
    }

    function _advancePool(uint256 poolId) internal {
        if (poolId >= _pools.length) revert UnknownPool(poolId);
        PoolInfo storage pool = _pools[poolId];
        if (block.timestamp == pool.lastTouched) return;
        if (pool.totalUnits > 0) {
            uint256 elapsed = block.timestamp - pool.lastTouched;
            pool.accPerUnit = pool.accPerUnit + (elapsed * pool.ratePerSecond * P) / pool.totalUnits;
        }
        pool.lastTouched = uint64(block.timestamp);
        emit PoolTouched(poolId, pool.accPerUnit);
    }

    /// Settlement helper for one (pool, account) pair. Returns the amount owed and resets the debt.
    function _harvestPoolFor(uint256 poolId, address account) internal returns (uint256) {
        _advancePool(poolId);
        uint256 units = unitsOf[poolId][account];
        int256 entitled = int256((units * _pools[poolId].accPerUnit) / P);
        int256 owed = entitled - debtOf[poolId][account];
        debtOf[poolId][account] = entitled;
        if (owed <= 0) return 0;
        return uint256(owed);
    }
}
