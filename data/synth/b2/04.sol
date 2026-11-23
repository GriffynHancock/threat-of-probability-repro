// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title Range-bounded liquidity positions with two fee tokens.
/// @notice Each (owner, tick range) pair is a position keyed by a hash.
/// Fee growth per unit of range liquidity is recorded by a keeper.
contract RangePositionFees {
    uint256 private constant Q = 1e18;

    struct Position {
        bytes32 rangeKey;
        uint128 liquidity;
        uint256 growth0Paid;
        uint256 growth1Paid;
        uint256 owed0;
        uint256 owed1;
    }

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    address public immutable keeper;

    mapping(bytes32 => Position) public positions;
    mapping(bytes32 => uint256) public rangeLiquidity;
    mapping(bytes32 => uint256) public growth0;
    mapping(bytes32 => uint256) public growth1;

    event Provided(address indexed owner, int24 lower, int24 upper, uint128 amount);
    event Withdrawn(address indexed owner, int24 lower, int24 upper, uint128 amount);
    event Collected(address indexed owner, uint256 amount0, uint256 amount1);
    event FeesRecorded(bytes32 indexed rangeKey, uint256 fee0, uint256 fee1);

    constructor(IERC20 _token0, IERC20 _token1, address _keeper) {
        token0 = _token0;
        token1 = _token1;
        keeper = _keeper;
    }

    function rangeKeyOf(int24 lower, int24 upper) public pure returns (bytes32) {
        return keccak256(abi.encode(lower, upper));
    }

    /// @notice Record fees earned by a range. Fees must already be held by this contract.
    function recordFees(int24 lower, int24 upper, uint256 fee0, uint256 fee1) external {
        require(msg.sender == keeper, "not keeper");
        bytes32 key = rangeKeyOf(lower, upper);
        uint256 liq = rangeLiquidity[key];
        require(liq > 0, "empty range");
        growth0[key] += fee0 * Q / liq;
        growth1[key] += fee1 * Q / liq;
        emit FeesRecorded(key, fee0, fee1);
    }

    function provide(int24 lower, int24 upper, uint128 amount) external {
        require(lower < upper, "bad range");
        require(amount > 0, "zero amount");
        bytes32 key = rangeKeyOf(lower, upper);
        bytes32 id = keccak256(abi.encode(msg.sender, key));
        _settlePosition(id, key);
        Position storage p = positions[id];
        p.liquidity += amount;
        rangeLiquidity[key] += amount;
        require(token0.transferFrom(msg.sender, address(this), amount), "transfer0 failed");
        emit Provided(msg.sender, lower, upper, amount);
    }

    function withdraw(int24 lower, int24 upper, uint128 amount) external {
        bytes32 key = rangeKeyOf(lower, upper);
        bytes32 id = keccak256(abi.encode(msg.sender, key));
        _settlePosition(id, key);
        Position storage p = positions[id];
        require(amount <= p.liquidity, "insufficient liquidity");
        p.liquidity -= amount;
        rangeLiquidity[key] -= amount;
        require(token0.transfer(msg.sender, amount), "transfer0 failed");
        emit Withdrawn(msg.sender, lower, upper, amount);
    }

    function collect(int24 lower, int24 upper) external {
        bytes32 key = rangeKeyOf(lower, upper);
        bytes32 id = keccak256(abi.encode(msg.sender, key));
        _settlePosition(id, key);
        Position storage p = positions[id];
        uint256 a0 = p.owed0;
        uint256 a1 = p.owed1;
        p.owed0 = 0;
        p.owed1 = 0;
        if (a0 > 0) require(token0.transfer(msg.sender, a0), "transfer0 failed");
        if (a1 > 0) require(token1.transfer(msg.sender, a1), "transfer1 failed");
        emit Collected(msg.sender, a0, a1);
    }

    /// @dev Credits fees accrued since the position's last snapshot. Uses the
    /// liquidity held before any change made by the caller.
    function _settlePosition(bytes32 id, bytes32 key) internal {
        Position storage p = positions[id];
        p.rangeKey = key;
        uint256 g0 = growth0[key];
        uint256 g1 = growth1[key];
        p.owed0 += uint256(p.liquidity) * (g0 - p.growth0Paid) / Q;
        p.owed1 += uint256(p.liquidity) * (g1 - p.growth1Paid) / Q;
        p.growth0Paid = g0;
        p.growth1Paid = g1;
    }
}
