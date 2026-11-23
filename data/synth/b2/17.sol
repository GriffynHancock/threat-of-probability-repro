// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Liquidity distributor with compact uint128 position storage.
/// Rewards are an index over total liquidity; each position carries a debt
/// denominated in index units.
contract CompactLiquidityDistributor {
    uint256 private constant INDEX_SCALE = 1e24;

    struct Position {
        uint128 liquidity;
        uint128 debt;
        uint256 unclaimed;
    }

    IERC20 public immutable liquidityAsset;
    IERC20 public immutable rewardAsset;
    address public immutable deployer;

    uint256 public index;
    uint128 public totalLiquidity;

    mapping(address => Position) public positions;

    event Committed(address indexed owner, uint128 amount);
    event Released(address indexed owner, uint128 amount);
    event Harvested(address indexed owner, uint256 amount);
    event IndexBumped(uint256 newIndex);

    constructor(IERC20 _liquidity, IERC20 _reward) {
        liquidityAsset = _liquidity;
        rewardAsset = _reward;
        deployer = msg.sender;
    }

    function bumpIndex(uint256 rewardAmount) external {
        require(msg.sender == deployer, "not deployer");
        require(totalLiquidity > 0, "no liquidity");
        require(rewardAsset.transferFrom(msg.sender, address(this), rewardAmount), "transfer failed");
        index += rewardAmount * INDEX_SCALE / totalLiquidity;
        emit IndexBumped(index);
    }

    function commitLiquidity(uint128 amount) external {
        require(amount > 0, "zero amount");
        _flushDebt(msg.sender);
        Position storage p = positions[msg.sender];
        p.liquidity += amount;
        p.debt = uint128(uint256(p.liquidity) * index / INDEX_SCALE);
        totalLiquidity += amount;
        require(liquidityAsset.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Committed(msg.sender, amount);
    }

    function releaseLiquidity(uint128 amount) external {
        Position storage p = positions[msg.sender];
        require(amount <= p.liquidity, "insufficient");
        _flushDebt(msg.sender);
        p.liquidity -= amount;
        p.debt = uint128(uint256(p.liquidity) * index / INDEX_SCALE);
        totalLiquidity -= amount;
        require(liquidityAsset.transfer(msg.sender, amount), "transfer failed");
        emit Released(msg.sender, amount);
    }

    function harvest() external {
        _flushDebt(msg.sender);
        Position storage p = positions[msg.sender];
        uint256 amount = p.unclaimed;
        if (amount == 0) return;
        p.unclaimed = 0;
        require(rewardAsset.transfer(msg.sender, amount), "transfer failed");
        emit Harvested(msg.sender, amount);
    }

    /// @dev Converts the index growth since the stored debt into unclaimed reward.
    function _flushDebt(address owner) internal {
        Position storage p = positions[owner];
        uint256 accrued = uint256(p.liquidity) * index / INDEX_SCALE;
        if (accrued > p.debt) {
            p.unclaimed += accrued - p.debt;
        }
        p.debt = uint128(accrued);
    }
}
