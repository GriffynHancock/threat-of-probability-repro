// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

error ZeroAmount();
error InsufficientLiquidity(uint256 have, uint256 want);
error NotFeeSource();
error TransferFailed();

/// @notice Single pool with fee-growth-per-liquidity accounting.
/// Positions are structs held in storage and mutated through a storage pointer.
contract FeeGrowthPool {
    uint256 private constant Q = 1e18;

    struct Position {
        uint256 liquidity;
        uint256 feeGrowthSnapshot;
        uint256 feesOwed;
    }

    IERC20 public immutable token0;
    IERC20 public immutable feeToken;
    address public immutable feeSource;

    uint256 public totalLiquidity;
    uint256 public feeGrowthGlobal;
    mapping(address => Position) public positions;

    event LiquidityAdded(address indexed who, uint256 amount);
    event LiquidityRemoved(address indexed who, uint256 amount);
    event FeesCollected(address indexed who, uint256 amount);
    event FeesNotified(uint256 amount);

    constructor(IERC20 _token0, IERC20 _feeToken, address _feeSource) {
        token0 = _token0;
        feeToken = _feeToken;
        feeSource = _feeSource;
    }

    /// @notice Called by the fee source after it has transferred fees in.
    function notifyFees(uint256 amount) external {
        if (msg.sender != feeSource) revert NotFeeSource();
        if (totalLiquidity == 0) revert InsufficientLiquidity(0, 1);
        if (!feeToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        feeGrowthGlobal += amount * Q / totalLiquidity;
        emit FeesNotified(amount);
    }

    function addLiquidity(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _updateFeeGrowth(msg.sender);
        Position storage p = positions[msg.sender];
        p.liquidity += amount;
        totalLiquidity += amount;
        if (!token0.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit LiquidityAdded(msg.sender, amount);
    }

    function removeLiquidity(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _updateFeeGrowth(msg.sender);
        Position storage p = positions[msg.sender];
        if (p.liquidity < amount) revert InsufficientLiquidity(p.liquidity, amount);
        p.liquidity -= amount;
        totalLiquidity -= amount;
        if (!token0.transfer(msg.sender, amount)) revert TransferFailed();
        emit LiquidityRemoved(msg.sender, amount);
    }

    function collectFees() external {
        _updateFeeGrowth(msg.sender);
        Position storage p = positions[msg.sender];
        uint256 owed = p.feesOwed;
        if (owed == 0) return;
        p.feesOwed = 0;
        if (!feeToken.transfer(msg.sender, owed)) revert TransferFailed();
        emit FeesCollected(msg.sender, owed);
    }

    /// @dev Moves the position's accrued fees into feesOwed and advances its snapshot.
    function _updateFeeGrowth(address who) internal {
        Position storage p = positions[who];
        uint256 delta = feeGrowthGlobal - p.feeGrowthSnapshot;
        p.feesOwed += p.liquidity * delta / Q;
        p.feeGrowthSnapshot = feeGrowthGlobal;
    }
}
