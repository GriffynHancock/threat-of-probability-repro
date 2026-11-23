// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract SharePriceVault {
    error ZeroAmount();
    error NotOwner();
    error InsufficientShares();
    error NoYieldToRealize();
    error TransferFailed();

    uint256 public constant PRECISION = 1e18;

    IERC20 public immutable asset;
    address public immutable owner;

    uint256 public totalShares;
    uint256 public managedAssets;
    uint256 public pendingYield;

    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public costBasis;

    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Redeemed(address indexed user, uint256 shares, uint256 assets);
    event YieldNotified(uint256 amount);
    event YieldSettled(uint256 amount, uint256 sharePrice);
    event YieldRealized(address indexed user, uint256 assets, uint256 sharesBurned);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IERC20 _asset) {
        asset = _asset;
        owner = msg.sender;
    }

    function sharePrice() public view returns (uint256) {
        if (totalShares == 0) return PRECISION;
        return managedAssets * PRECISION / totalShares;
    }

    function notifyYield(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        pendingYield += amount;
        if (!asset.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit YieldNotified(amount);
    }

    // Settlement runs first so every mint below is priced against current assets.
    function deposit(uint256 assets) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _syncAssets();

        shares = totalShares == 0 ? assets : assets * totalShares / managedAssets;
        if (shares == 0) revert ZeroAmount();

        sharesOf[msg.sender] += shares;
        totalShares += shares;
        managedAssets += assets;
        costBasis[msg.sender] += assets;

        if (!asset.transferFrom(msg.sender, address(this), assets)) revert TransferFailed();
        emit Deposited(msg.sender, assets, shares);
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        _syncAssets();

        uint256 held = sharesOf[msg.sender];
        if (shares > held) revert InsufficientShares();

        assets = shares * managedAssets / totalShares;
        uint256 basisOut = costBasis[msg.sender] * shares / held;

        sharesOf[msg.sender] = held - shares;
        totalShares -= shares;
        managedAssets -= assets;
        costBasis[msg.sender] -= basisOut;
        if (totalShares == 0) managedAssets = 0;

        if (!asset.transfer(msg.sender, assets)) revert TransferFailed();
        emit Redeemed(msg.sender, shares, assets);
    }

    // Pays out only the gain above cost basis, by burning the equivalent shares.
    function realizeYield() external returns (uint256 assets) {
        _syncAssets();

        uint256 held = sharesOf[msg.sender];
        if (held == 0) revert NoYieldToRealize();

        uint256 value = held * managedAssets / totalShares;
        uint256 basis = costBasis[msg.sender];
        if (value <= basis) revert NoYieldToRealize();

        uint256 excess = value - basis;
        uint256 burn = (excess * totalShares + managedAssets - 1) / managedAssets;
        assets = burn * managedAssets / totalShares;

        sharesOf[msg.sender] = held - burn;
        totalShares -= burn;
        managedAssets -= assets;

        if (!asset.transfer(msg.sender, assets)) revert TransferFailed();
        emit YieldRealized(msg.sender, assets, burn);
    }

    function _syncAssets() internal {
        if (totalShares == 0 || pendingYield == 0) return;
        uint256 settled = pendingYield;
        pendingYield = 0;
        managedAssets += settled;
        emit YieldSettled(settled, sharePrice());
    }
}
