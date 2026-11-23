// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Share-price liquid staking token. Rewards stream from an admin-funded reserve.
contract ShareLST {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant COOLDOWN = 7 days;

    struct Exit {
        uint256 assets;
        uint256 readyAt;
        bool claimed;
    }

    IERC20 public immutable asset;
    address public immutable admin;

    uint256 public totalShares;
    uint256 public totalPooled;
    uint256 public rewardReserve;
    uint256 public rewardsPerSecond;
    uint256 public lastRefresh;

    mapping(address => uint256) public sharesOf;
    mapping(address => Exit[]) public exitsOf;

    event Submitted(address indexed user, uint256 assets, uint256 shares);
    event ExitRequested(address indexed user, uint256 index, uint256 shares, uint256 assets);
    event ExitClaimed(address indexed user, uint256 index, uint256 assets);
    event RewardsFunded(uint256 amount);
    event ExchangeRefreshed(uint256 accrued, uint256 totalPooled);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    constructor(IERC20 _asset, uint256 _rewardsPerSecond) {
        asset = _asset;
        admin = msg.sender;
        rewardsPerSecond = _rewardsPerSecond;
        lastRefresh = block.timestamp;
    }

    function exchangeRate() public view returns (uint256) {
        if (totalShares == 0) return PRECISION;
        return (totalPooled * PRECISION) / totalShares;
    }

    function fundRewards(uint256 amount) external onlyAdmin {
        require(amount > 0, "zero");
        rewardReserve += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "pull");
        emit RewardsFunded(amount);
    }

    function _refreshExchangeRate() internal {
        uint256 elapsed = block.timestamp - lastRefresh;
        lastRefresh = block.timestamp;
        uint256 accrued = elapsed * rewardsPerSecond;
        if (accrued > rewardReserve) accrued = rewardReserve;
        if (accrued == 0) return;
        rewardReserve -= accrued;
        totalPooled += accrued;
        emit ExchangeRefreshed(accrued, totalPooled);
    }

    function submit(uint256 assets) external returns (uint256 shares) {
        require(assets > 0, "zero");
        _refreshExchangeRate();
        if (totalShares == 0) {
            shares = assets;
        } else {
            require(totalPooled > 0, "empty pool");
            shares = (assets * totalShares) / totalPooled;
        }
        require(shares > 0, "dust");
        sharesOf[msg.sender] += shares;
        totalShares += shares;
        totalPooled += assets;
        emit Submitted(msg.sender, assets, shares);
        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
    }

    function requestUnstake(uint256 shares) external returns (uint256 index) {
        require(shares > 0, "zero");
        _refreshExchangeRate();
        require(sharesOf[msg.sender] >= shares, "insufficient");
        uint256 assets = (shares * totalPooled) / totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        totalPooled -= assets;
        exitsOf[msg.sender].push(Exit({assets: assets, readyAt: block.timestamp + COOLDOWN, claimed: false}));
        index = exitsOf[msg.sender].length - 1;
        emit ExitRequested(msg.sender, index, shares, assets);
    }

    function claimUnstake(uint256 index) external returns (uint256 assets) {
        Exit[] storage queue = exitsOf[msg.sender];
        require(index < queue.length, "bad index");
        Exit storage e = queue[index];
        require(!e.claimed, "claimed");
        require(block.timestamp >= e.readyAt, "cooldown");
        e.claimed = true;
        assets = e.assets;
        require(asset.transfer(msg.sender, assets), "xfer");
        emit ExitClaimed(msg.sender, index, assets);
    }
}
