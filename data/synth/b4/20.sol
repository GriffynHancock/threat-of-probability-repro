// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title MultiPoolInsuranceRouter
/// @notice Several cover pools share one asset. A treasurer routes premiums to each pool;
///         providers hold independent positions per pool and settle per pool.
contract MultiPoolInsuranceRouter {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant POOL_COUNT = 2;

    IERC20 public immutable asset;
    address public immutable treasurer;

    mapping(uint256 => uint256) public poolCapitalTotal;
    mapping(uint256 => uint256) public poolIndex;
    mapping(uint256 => mapping(address => uint256)) public poolCapital;
    mapping(uint256 => mapping(address => uint256)) public poolDebt;
    mapping(uint256 => mapping(address => uint256)) public poolOwed;

    event CoverAdded(uint256 indexed poolId, address indexed who, uint256 amount);
    event CoverWithdrawn(uint256 indexed poolId, address indexed who, uint256 amount);
    event PremiumsRouted(uint256 indexed poolId, uint256 amount);
    event PremiumsClaimed(uint256 indexed poolId, address indexed who, uint256 amount);

    constructor(IERC20 _asset) {
        asset = _asset;
        treasurer = msg.sender;
    }

    function routePremiums(uint256 poolId, uint256 amount) external {
        require(msg.sender == treasurer, "not treasurer");
        require(poolId < POOL_COUNT, "bad pool");
        require(poolCapitalTotal[poolId] > 0, "empty pool");
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer failed");
        poolIndex[poolId] += (amount * PRECISION) / poolCapitalTotal[poolId];
        emit PremiumsRouted(poolId, amount);
    }

    function _routePremiums(uint256 poolId, address who) internal {
        poolOwed[poolId][who] +=
            (poolCapital[poolId][who] * (poolIndex[poolId] - poolDebt[poolId][who])) / PRECISION;
        poolDebt[poolId][who] = poolIndex[poolId];
    }

    /// @notice Provide cover to a pool.
    function cover(uint256 poolId, uint256 amount) external {
        require(poolId < POOL_COUNT, "bad pool");
        require(amount > 0, "zero amount");
        _routePremiums(poolId, msg.sender);
        poolCapital[poolId][msg.sender] += amount;
        poolCapitalTotal[poolId] += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit CoverAdded(poolId, msg.sender, amount);
    }

    /// @notice Withdraw cover from a pool.
    function withdrawCover(uint256 poolId, uint256 amount) external {
        _routePremiums(poolId, msg.sender);
        require(poolCapital[poolId][msg.sender] >= amount, "insufficient cover");
        poolCapital[poolId][msg.sender] -= amount;
        poolCapitalTotal[poolId] -= amount;
        require(asset.transfer(msg.sender, amount), "transfer failed");
        emit CoverWithdrawn(poolId, msg.sender, amount);
    }

    /// @notice Claim premiums from a pool.
    function claimPremiums(uint256 poolId) external {
        _routePremiums(poolId, msg.sender);
        uint256 amount = poolOwed[poolId][msg.sender];
        require(amount > 0, "nothing owed");
        poolOwed[poolId][msg.sender] = 0;
        require(asset.transfer(msg.sender, amount), "transfer failed");
        emit PremiumsClaimed(poolId, msg.sender, amount);
    }
}
