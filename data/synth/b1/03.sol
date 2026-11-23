// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title CollateralDebtShares
/// @notice Single-token lending book. Debt is tracked as shares against a global
///         debt-per-share index that grows linearly per second.
contract CollateralDebtShares {
    uint256 private constant SCALE = 1e18;
    uint256 private constant COLLATERAL_FACTOR = 75e16;
    uint256 private constant RATE_PER_SEC = 4e9;

    /// Packed into one storage slot: 16 + 16 + 8 + 8 bytes.
    struct Position {
        uint128 collateral;
        uint128 debtShares;
        uint64 settledAt;
        uint64 reserved;
    }

    IERC20 public immutable token;
    address public immutable admin;

    uint256 public debtPerShare = SCALE;
    uint256 public lastAccrual;
    uint256 public totalDebtShares;
    uint256 public totalCollateral;
    uint256 public totalCash;

    mapping(address => Position) public positions;

    event CollateralAdded(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event DebtDrawn(address indexed user, uint256 amount, uint256 shares);
    event DebtRepaid(address indexed user, uint256 amount);
    event LiquidityFunded(uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        admin = msg.sender;
        lastAccrual = block.timestamp;
    }

    function fundLiquidity(uint256 amount) external {
        require(msg.sender == admin, "not admin");
        totalCash += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit LiquidityFunded(amount);
    }

    /// @dev Advances the global index, then stamps the user's position as settled.
    function _settle(address user) internal {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt > 0) {
            if (totalDebtShares > 0) {
                debtPerShare += (debtPerShare * RATE_PER_SEC * dt) / SCALE;
            }
            lastAccrual = block.timestamp;
        }
        positions[user].settledAt = uint64(block.timestamp);
    }

    function _debtOf(Position storage p) internal view returns (uint256) {
        return (uint256(p.debtShares) * debtPerShare) / SCALE;
    }

    function _healthy(Position storage p) internal view returns (bool) {
        return _debtOf(p) <= (uint256(p.collateral) * COLLATERAL_FACTOR) / SCALE;
    }

    function addCollateral(uint256 amount) external {
        require(amount > 0 && amount <= type(uint128).max, "amount");
        _settle(msg.sender);
        Position storage p = positions[msg.sender];
        p.collateral += uint128(amount);
        totalCollateral += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit CollateralAdded(msg.sender, amount);
    }

    function drawDebt(uint256 amount) external {
        _settle(msg.sender);
        require(amount > 0 && amount <= totalCash, "liquidity");
        uint256 shares = (amount * SCALE) / debtPerShare;
        Position storage p = positions[msg.sender];
        p.debtShares += uint128(shares);
        totalDebtShares += shares;
        require(_healthy(p), "undercollateralised");
        totalCash -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit DebtDrawn(msg.sender, amount, shares);
    }

    function repay(uint256 amount) external {
        _settle(msg.sender);
        Position storage p = positions[msg.sender];
        uint256 owed = _debtOf(p);
        uint256 pay = amount > owed ? owed : amount;
        uint256 burn = (pay * SCALE) / debtPerShare;
        p.debtShares -= uint128(burn);
        totalDebtShares -= burn;
        totalCash += pay;
        require(token.transferFrom(msg.sender, address(this), pay), "transferFrom");
        emit DebtRepaid(msg.sender, pay);
    }

    function withdrawCollateral(uint256 amount) external {
        _settle(msg.sender);
        Position storage p = positions[msg.sender];
        require(amount <= p.collateral, "collateral");
        p.collateral -= uint128(amount);
        totalCollateral -= amount;
        require(_healthy(p), "undercollateralised");
        require(token.transfer(msg.sender, amount), "transfer");
        emit CollateralWithdrawn(msg.sender, amount);
    }
}
