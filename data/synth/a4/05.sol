// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/**
 * @notice Yield pool where manager-supplied rewards vest linearly over STREAM_WINDOW.
 * Vesting is settled lazily by _collect(), which every state-changing path calls first.
 */
contract StreamingYieldPool {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant STREAM_WINDOW = 1 days;
    uint256 public constant PERF_FEE_BPS = 1_000;

    IERC20Like public immutable underlying;
    address public immutable manager;

    uint256 public totalShares;
    uint256 public assetsHeld;
    uint256 public unvested;
    uint256 public streamEnd;
    uint256 public lastVest;
    uint256 public feesAccrued;

    mapping(address => uint256) public balances;

    event Subscribed(address indexed who, uint256 assets, uint256 shares);
    event CashedOut(address indexed who, uint256 shares, uint256 assets);
    event StreamTopped(uint256 amount, uint256 streamEnd);
    event Vested(uint256 toHolders, uint256 toFees);
    event FeesClaimed(uint256 amount);

    constructor(IERC20Like _underlying) {
        underlying = _underlying;
        manager = msg.sender;
    }

    function pricePerShare() external view returns (uint256) {
        if (totalShares == 0) return WAD;
        return assetsHeld * WAD / totalShares;
    }

    function topStream(uint256 amount) external {
        require(msg.sender == manager, "only manager");
        require(amount > 0, "zero");
        _collect();
        unvested += amount;
        lastVest = block.timestamp;
        streamEnd = block.timestamp + STREAM_WINDOW;
        require(underlying.transferFrom(msg.sender, address(this), amount), "pull");
        emit StreamTopped(amount, streamEnd);
    }

    function subscribe(uint256 assets) external returns (uint256 shares) {
        require(assets > 0, "zero");
        _collect();

        if (totalShares == 0) {
            shares = assets;
        } else {
            require(assetsHeld > 0, "no backing");
            shares = assets * totalShares / assetsHeld;
        }
        require(shares > 0, "dust");

        balances[msg.sender] += shares;
        totalShares += shares;
        assetsHeld += assets;

        require(underlying.transferFrom(msg.sender, address(this), assets), "pull");
        emit Subscribed(msg.sender, assets, shares);
    }

    function cashOut(uint256 shares) external returns (uint256 assets) {
        require(shares > 0 && balances[msg.sender] >= shares, "bad shares");
        _collect();

        assets = shares * assetsHeld / totalShares;

        balances[msg.sender] -= shares;
        totalShares -= shares;
        assetsHeld -= assets;

        require(underlying.transfer(msg.sender, assets), "push");
        emit CashedOut(msg.sender, shares, assets);
    }

    function claimFees() external returns (uint256 amount) {
        require(msg.sender == manager, "only manager");
        _collect();
        amount = feesAccrued;
        if (amount == 0) return 0;
        feesAccrued = 0;
        require(underlying.transfer(manager, amount), "push");
        emit FeesClaimed(amount);
    }

    function _collect() internal {
        uint256 cursor = block.timestamp < streamEnd ? block.timestamp : streamEnd;
        if (cursor <= lastVest) return;

        uint256 span = streamEnd - lastVest;
        uint256 vested = unvested * (cursor - lastVest) / span;
        unvested -= vested;
        lastVest = cursor;

        uint256 fee = vested * PERF_FEE_BPS / BPS;
        feesAccrued += fee;
        assetsHeld += vested - fee;
        emit Vested(vested - fee, fee);
    }
}
