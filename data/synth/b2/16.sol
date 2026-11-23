// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Share-priced liquidity vault. Fees received raise the value of each
/// share; a holder's fee entitlement is settled into a pending balance before
/// its share count changes.
contract SharePricedFeeVault {
    uint256 private constant ONE = 1e18;

    IERC20 public immutable asset;
    IERC20 public immutable feeAsset;
    address public immutable collector;

    uint256 public totalShares;
    uint256 public totalAssets;
    uint256 public feePerShare;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public feeDebt;
    mapping(address => uint256) public feesPending;

    event FeesReceived(uint256 amount, uint256 feePerShare);
    event Supplied(address indexed user, uint256 assets, uint256 minted);
    event Redeemed(address indexed user, uint256 shares, uint256 assets);
    event FeesWithdrawn(address indexed user, uint256 amount);

    constructor(IERC20 _asset, IERC20 _feeAsset) {
        asset = _asset;
        feeAsset = _feeAsset;
        collector = msg.sender;
    }

    function receiveFees(uint256 amount) external {
        require(msg.sender == collector, "not collector");
        require(totalShares > 0, "no shares");
        require(feeAsset.transferFrom(msg.sender, address(this), amount), "transfer failed");
        feePerShare += amount * ONE / totalShares;
        emit FeesReceived(amount, feePerShare);
    }

    function supplyAssets(uint256 assets) external {
        require(assets > 0, "zero assets");
        _bankFees(msg.sender);
        uint256 minted = totalShares == 0 || totalAssets == 0
            ? assets
            : assets * totalShares / totalAssets;
        shares[msg.sender] += minted;
        totalShares += minted;
        totalAssets += assets;
        feeDebt[msg.sender] = shares[msg.sender] * feePerShare / ONE;
        require(asset.transferFrom(msg.sender, address(this), assets), "transfer failed");
        emit Supplied(msg.sender, assets, minted);
    }

    function redeemShares(uint256 amount) external {
        require(amount <= shares[msg.sender], "insufficient shares");
        _bankFees(msg.sender);
        uint256 assets = amount * totalAssets / totalShares;
        shares[msg.sender] -= amount;
        totalShares -= amount;
        totalAssets -= assets;
        feeDebt[msg.sender] = shares[msg.sender] * feePerShare / ONE;
        require(asset.transfer(msg.sender, assets), "transfer failed");
        emit Redeemed(msg.sender, amount, assets);
    }

    function withdrawFees() external {
        _bankFees(msg.sender);
        uint256 amount = feesPending[msg.sender];
        if (amount == 0) return;
        feesPending[msg.sender] = 0;
        require(feeAsset.transfer(msg.sender, amount), "transfer failed");
        emit FeesWithdrawn(msg.sender, amount);
    }

    /// @dev Banks fees earned on the caller's current shares, then resets its debt
    /// to the present per-share index. Must run before any change to shares[who].
    function _bankFees(address who) internal {
        uint256 earned = shares[who] * feePerShare / ONE;
        if (earned > feeDebt[who]) {
            feesPending[who] += earned - feeDebt[who];
        }
        feeDebt[who] = shares[who] * feePerShare / ONE;
    }
}
