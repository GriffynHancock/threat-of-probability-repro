// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IStrategyAdapter {
    function balance() external view returns (uint256);
}

/// @notice Multi-strategy yield router. Deposits sit idle until the governor deploys them to adapters.
contract YieldRouterAllocator {
    uint256 private constant BPS = 10_000;
    uint256 public constant REDEEM_DELAY = 2 days;

    struct Strategy {
        IStrategyAdapter adapter;
        uint256 deployed;
        uint256 weightBps;
        bool enabled;
    }

    struct Redeem {
        uint256 shares;
        uint256 assets;
        uint256 readyAt;
    }

    IERC20 public immutable asset;
    address public immutable governor;

    Strategy[] public strategies;
    uint256 public totalShares;
    uint256 public idle;
    uint256 public reserved;

    mapping(address => uint256) public shares;
    mapping(address => Redeem) public redeems;

    event StrategyAdded(uint256 indexed id, address adapter, uint256 weightBps);
    event Harvested(uint256 indexed id, uint256 previous, uint256 observed);
    event Deployed(uint256 indexed id, uint256 amount);
    event Allocated(address indexed user, uint256 assets, uint256 shares);
    event RedeemRequested(address indexed user, uint256 shares, uint256 assets, uint256 readyAt);
    event RedeemClaimed(address indexed user, uint256 assets);

    constructor(IERC20 _asset) {
        asset = _asset;
        governor = msg.sender;
    }

    modifier onlyGovernor() {
        require(msg.sender == governor, "gov");
        _;
    }

    function addStrategy(IStrategyAdapter adapter, uint256 weightBps) external onlyGovernor {
        require(weightBps <= BPS, "weight");
        strategies.push(Strategy({adapter: adapter, deployed: 0, weightBps: weightBps, enabled: true}));
        emit StrategyAdded(strategies.length - 1, address(adapter), weightBps);
    }

    function totalAssets() public view returns (uint256 total) {
        total = idle;
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            total += strategies[i].deployed;
        }
    }

    function _harvestAllStrategies() internal {
        uint256 n = strategies.length;
        for (uint256 i = 0; i < n; i++) {
            Strategy storage s = strategies[i];
            if (!s.enabled) continue;
            uint256 observed = s.adapter.balance();
            if (observed != s.deployed) {
                emit Harvested(i, s.deployed, observed);
                s.deployed = observed;
            }
        }
    }

    function deploy(uint256 id, uint256 amount) external onlyGovernor {
        Strategy storage s = strategies[id];
        require(s.enabled, "disabled");
        require(amount <= idle, "idle");
        idle -= amount;
        s.deployed += amount;
        emit Deployed(id, amount);
        require(asset.transfer(address(s.adapter), amount), "xfer");
    }

    function allocate(uint256 assets) external returns (uint256 minted) {
        require(assets > 0, "zero");
        _harvestAllStrategies();
        uint256 nav = totalAssets();
        if (totalShares == 0) {
            minted = assets;
        } else {
            require(nav > 0, "nav");
            minted = (assets * totalShares) / nav;
        }
        require(minted > 0, "dust");
        shares[msg.sender] += minted;
        totalShares += minted;
        idle += assets;
        emit Allocated(msg.sender, assets, minted);
        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
    }

    function requestRedeem(uint256 amount) external {
        require(amount > 0, "zero");
        _harvestAllStrategies();
        require(shares[msg.sender] >= amount, "balance");
        require(redeems[msg.sender].assets == 0, "pending");
        uint256 assets = (amount * totalAssets()) / totalShares;
        require(assets <= idle, "liquidity");
        shares[msg.sender] -= amount;
        totalShares -= amount;
        idle -= assets;
        reserved += assets;
        uint256 readyAt = block.timestamp + REDEEM_DELAY;
        redeems[msg.sender] = Redeem({shares: amount, assets: assets, readyAt: readyAt});
        emit RedeemRequested(msg.sender, amount, assets, readyAt);
    }

    function claimRedeem() external returns (uint256 out) {
        Redeem storage r = redeems[msg.sender];
        require(r.assets > 0, "none");
        require(block.timestamp >= r.readyAt, "cooldown");
        out = r.assets;
        reserved -= out;
        delete redeems[msg.sender];
        emit RedeemClaimed(msg.sender, out);
        require(asset.transfer(msg.sender, out), "xfer");
    }
}
