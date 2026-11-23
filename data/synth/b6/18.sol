// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Share vault with virtual offsets. Shares are minted in exact amounts; assets are priced up.
contract VirtualShareVault {
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint256 public constant PAYOUT_DELAY = 1 days;

    IERC20 public immutable asset;
    address public immutable owner;
    uint256 public immutable yieldRate;

    uint256 public yieldReserve;
    uint256 public lastSync;
    uint256 public totalSupply;
    uint256 public totalAssetsTracked;
    uint256 public reservedAssets;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public payoutOwed;
    mapping(address => uint256) public payoutReadyAt;

    event Minted(address indexed user, uint256 shares, uint256 assets);
    event Redeemed(address indexed user, uint256 shares, uint256 assets);
    event PayoutClaimed(address indexed user, uint256 assets);
    event YieldSynced(uint256 gain, uint256 totalAssetsTracked);
    event YieldFunded(uint256 amount);

    constructor(IERC20 _asset, uint256 _yieldRate) {
        asset = _asset;
        owner = msg.sender;
        yieldRate = _yieldRate;
        lastSync = block.timestamp;
    }

    function fundYield(uint256 amount) external {
        require(msg.sender == owner, "not owner");
        yieldReserve += amount;
        emit YieldFunded(amount);
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function _syncVaultPrice() internal {
        uint256 dt = block.timestamp - lastSync;
        lastSync = block.timestamp;
        if (dt == 0) return;
        uint256 gain = dt * yieldRate;
        if (gain > yieldReserve) gain = yieldReserve;
        if (gain == 0) return;
        yieldReserve -= gain;
        totalAssetsTracked += gain;
        emit YieldSynced(gain, totalAssetsTracked);
    }

    function mint(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "zero");
        _syncVaultPrice();
        assets = _ceilDiv(shares * (totalAssetsTracked + VIRTUAL_ASSETS), totalSupply + VIRTUAL_SHARES);
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
        totalAssetsTracked += assets;
        emit Minted(msg.sender, shares, assets);
        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "zero");
        _syncVaultPrice();
        require(balanceOf[msg.sender] >= shares, "balance");
        assets = (shares * (totalAssetsTracked + VIRTUAL_ASSETS)) / (totalSupply + VIRTUAL_SHARES);
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        totalAssetsTracked -= assets;
        payoutOwed[msg.sender] += assets;
        payoutReadyAt[msg.sender] = block.timestamp + PAYOUT_DELAY;
        reservedAssets += assets;
        emit Redeemed(msg.sender, shares, assets);
    }

    function withdrawPayout() external returns (uint256 amount) {
        amount = payoutOwed[msg.sender];
        require(amount > 0, "none");
        require(block.timestamp >= payoutReadyAt[msg.sender], "locked");
        payoutOwed[msg.sender] = 0;
        reservedAssets -= amount;
        emit PayoutClaimed(msg.sender, amount);
        require(asset.transfer(msg.sender, amount), "xfer");
    }
}
