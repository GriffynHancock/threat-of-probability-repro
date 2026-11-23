// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SharedVaultProvision
/// @notice Pooled vault in the ERC-4626 share style. The operator deploys idle cash as
///         strategy debt; that debt accrues interest on a kinked utilisation curve.
contract SharedVaultProvision {
    uint256 private constant SCALE = 1e18;
    uint256 private constant BASE = 1e16;
    uint256 private constant SLOPE_1 = 4e16;
    uint256 private constant SLOPE_2 = 80e16;
    uint256 private constant KINK = 80e16;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    error ZeroAssets();
    error ExceedsIdle(uint256 wanted, uint256 idle);
    error NotOperator();

    IERC20 public immutable asset;
    address public immutable operator;

    uint256 public totalShares;
    uint256 public idleCash;
    uint256 public strategyDebt;
    uint256 public lastSync;

    mapping(address => uint256) public shareOf;

    event Provided(address indexed who, uint256 assets, uint256 shares);
    event Redeemed(address indexed who, uint256 shares, uint256 assets);
    event Deployed(uint256 assets);
    event Synced(uint256 interest, uint256 rate);

    constructor(IERC20 _asset) {
        asset = _asset;
        operator = msg.sender;
        lastSync = block.timestamp;
    }

    function utilization() public view returns (uint256) {
        uint256 total = idleCash + strategyDebt;
        return total == 0 ? 0 : (strategyDebt * SCALE) / total;
    }

    /// @notice Annual borrow rate, scaled by 1e18.
    function borrowRate() public view returns (uint256) {
        uint256 u = utilization();
        if (u <= KINK) {
            return BASE + (u * SLOPE_1) / KINK;
        }
        return BASE + SLOPE_1 + ((u - KINK) * SLOPE_2) / (SCALE - KINK);
    }

    function totalAssets() public view returns (uint256) {
        return idleCash + strategyDebt;
    }

    function _syncMarket() internal {
        uint256 elapsed = block.timestamp - lastSync;
        lastSync = block.timestamp;
        if (elapsed == 0 || strategyDebt == 0) return;
        uint256 rate = borrowRate();
        uint256 interest = (strategyDebt * rate * elapsed) / (SCALE * SECONDS_PER_YEAR);
        strategyDebt += interest;
        emit Synced(interest, rate);
    }

    function provide(uint256 assets) external {
        if (assets == 0) revert ZeroAssets();
        _syncMarket();
        uint256 supply = totalAssets();
        uint256 shares = totalShares == 0 ? assets : (assets * totalShares) / supply;
        shareOf[msg.sender] += shares;
        totalShares += shares;
        idleCash += assets;
        require(asset.transferFrom(msg.sender, address(this), assets), "transferFrom");
        emit Provided(msg.sender, assets, shares);
    }

    function redeem(uint256 shares) external {
        _syncMarket();
        require(shares > 0 && shares <= shareOf[msg.sender], "shares");
        uint256 assets = (shares * totalAssets()) / totalShares;
        if (assets > idleCash) revert ExceedsIdle(assets, idleCash);
        shareOf[msg.sender] -= shares;
        totalShares -= shares;
        idleCash -= assets;
        require(asset.transfer(msg.sender, assets), "transfer");
        emit Redeemed(msg.sender, shares, assets);
    }

    function deploy(uint256 assets) external {
        if (msg.sender != operator) revert NotOperator();
        if (assets > idleCash) revert ExceedsIdle(assets, idleCash);
        _syncMarket();
        idleCash -= assets;
        strategyDebt += assets;
        emit Deployed(assets);
    }
}
