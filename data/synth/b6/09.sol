// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Share token with a performance fee skimmed to treasury as newly minted shares.
contract FeeSkimStakeToken {
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_FEE_BPS = 2_000;

    IERC20 public immutable asset;
    address public immutable treasury;
    address public immutable admin;

    uint256 public feeBps;
    uint256 public yieldPerSecond;
    uint256 public yieldReserve;
    uint256 public lastSkim;

    uint256 public totalShares;
    uint256 public totalAssetsTracked;

    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public pendingOut;

    event Staked(address indexed user, uint256 assets, uint256 shares);
    event Unstaked(address indexed user, uint256 shares, uint256 assets);
    event FeeSkimmed(uint256 fee, uint256 feeShares);
    event PayoutCollected(address indexed user, uint256 amount);
    event YieldFunded(uint256 amount);

    constructor(IERC20 _asset, address _treasury, uint256 _feeBps, uint256 _yieldPerSecond) {
        require(_feeBps <= MAX_FEE_BPS, "fee cap");
        asset = _asset;
        treasury = _treasury;
        admin = msg.sender;
        feeBps = _feeBps;
        yieldPerSecond = _yieldPerSecond;
        lastSkim = block.timestamp;
    }

    function fundYield(uint256 amount) external {
        require(msg.sender == admin, "not admin");
        yieldReserve += amount;
        emit YieldFunded(amount);
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function _realizeFees() internal {
        uint256 dt = block.timestamp - lastSkim;
        lastSkim = block.timestamp;
        if (dt == 0 || totalShares == 0) return;
        uint256 accrued = dt * yieldPerSecond;
        if (accrued > yieldReserve) accrued = yieldReserve;
        if (accrued == 0) return;
        yieldReserve -= accrued;
        totalAssetsTracked += accrued;
        uint256 fee = (accrued * feeBps) / BPS;
        uint256 feeShares = 0;
        if (fee > 0) {
            // price including the fee is (T + accrued) / S; mint f so that f * price = fee
            feeShares = (fee * totalShares) / (totalAssetsTracked - fee);
            sharesOf[treasury] += feeShares;
            totalShares += feeShares;
        }
        emit FeeSkimmed(fee, feeShares);
    }

    function stake(uint256 assets) external returns (uint256 minted) {
        require(assets > 0, "zero");
        _realizeFees();
        minted = totalShares == 0 ? assets : (assets * totalShares) / totalAssetsTracked;
        require(minted > 0, "dust");
        sharesOf[msg.sender] += minted;
        totalShares += minted;
        totalAssetsTracked += assets;
        emit Staked(msg.sender, assets, minted);
        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
    }

    function unstake(uint256 shares) external returns (uint256 assets) {
        require(shares > 0, "zero");
        _realizeFees();
        require(sharesOf[msg.sender] >= shares, "insufficient");
        assets = (shares * totalAssetsTracked) / totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssetsTracked -= assets;
        pendingOut[msg.sender] += assets;
        emit Unstaked(msg.sender, shares, assets);
    }

    function collectUnstaked() external returns (uint256 amount) {
        amount = pendingOut[msg.sender];
        require(amount > 0, "none");
        pendingOut[msg.sender] = 0;
        emit PayoutCollected(msg.sender, amount);
        require(asset.transfer(msg.sender, amount), "xfer");
    }
}
