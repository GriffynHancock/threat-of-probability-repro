// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SharesRebaseSupply
/// @notice Rebasing supply: holders own shares of a pool whose asset total grows at a
///         per-second yield. Balance is derived as shares times the asset-per-share ratio.
contract SharesRebaseSupply {
    uint256 private constant SCALE = 1e18;

    IERC20 public immutable token;
    address public immutable steward;

    uint256 public yieldPerSecond;
    uint256 public lastRebase;
    uint256 public totalShares;
    uint256 public totalAssets;

    mapping(address => uint256) public sharesOf;

    event Entered(address indexed who, uint256 assets, uint256 shares);
    event Left(address indexed who, uint256 shares, uint256 assets);
    event Rebased(uint256 newTotalAssets);

    constructor(IERC20 _token, uint256 _yieldPerSecond) {
        token = _token;
        steward = msg.sender;
        yieldPerSecond = _yieldPerSecond;
        lastRebase = block.timestamp;
    }

    function balanceOf(address who) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesOf[who] * totalAssets) / totalShares;
    }

    function _rebase() internal {
        uint256 dt = block.timestamp - lastRebase;
        lastRebase = block.timestamp;
        if (dt == 0 || totalShares == 0) return;
        totalAssets += (totalAssets * yieldPerSecond * dt) / SCALE;
        emit Rebased(totalAssets);
    }

    function enter(uint256 assets) external {
        require(assets > 0, "zero");
        _rebase();
        uint256 shares = totalShares == 0 ? assets : (assets * totalShares) / totalAssets;
        require(shares > 0, "dust");
        sharesOf[msg.sender] += shares;
        totalShares += shares;
        totalAssets += assets;
        require(token.transferFrom(msg.sender, address(this), assets), "transferFrom");
        emit Entered(msg.sender, assets, shares);
    }

    function leave(uint256 shares) external {
        _rebase();
        require(shares > 0 && shares <= sharesOf[msg.sender], "shares");
        uint256 assets = (shares * totalAssets) / totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= assets;
        require(token.transfer(msg.sender, assets), "transfer");
        emit Left(msg.sender, shares, assets);
    }

    function leaveAll() external returns (uint256 assets) {
        _rebase();
        uint256 shares = sharesOf[msg.sender];
        require(shares > 0, "nothing");
        assets = (shares * totalAssets) / totalShares;
        sharesOf[msg.sender] = 0;
        totalShares -= shares;
        totalAssets -= assets;
        require(token.transfer(msg.sender, assets), "transfer");
        emit Left(msg.sender, shares, assets);
    }
}
