// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Round-based aggregator. A keeper closes rounds with a valuation; entries price at the last rolled price.
contract RoundBasedAggregator {
    uint256 private constant PRECISION = 1e18;

    struct Position {
        uint256 shares;
        uint256 entryRound;
        uint256 claimable;
    }

    IERC20 public immutable asset;
    address public immutable keeper;

    uint256 public currentRound;
    uint256 public totalShares;
    uint256 public pendingPrice;
    uint256 public latestPrice;

    mapping(address => Position) public positions;
    mapping(uint256 => uint256) public roundPrice;

    event RoundClosed(uint256 indexed round, uint256 valuation, uint256 price);
    event PriceRolled(uint256 price);
    event RoundEntered(address indexed user, uint256 indexed round, uint256 assets, uint256 shares);
    event RoundExited(address indexed user, uint256 indexed round, uint256 shares, uint256 value);
    event PayoutClaimed(address indexed user, uint256 amount);

    constructor(IERC20 _asset) {
        asset = _asset;
        keeper = msg.sender;
    }

    function closeRound(uint256 newValuation) external {
        require(msg.sender == keeper, "not keeper");
        require(totalShares > 0, "no shares");
        uint256 price = (newValuation * PRECISION) / totalShares;
        roundPrice[currentRound] = price;
        pendingPrice = price;
        emit RoundClosed(currentRound, newValuation, price);
        currentRound++;
    }

    function _rollForward() internal {
        if (pendingPrice != latestPrice) {
            latestPrice = pendingPrice;
            emit PriceRolled(latestPrice);
        }
    }

    function enterRound(uint256 assets) external returns (uint256 minted) {
        require(assets > 0, "zero");
        _rollForward();
        uint256 price = latestPrice == 0 ? PRECISION : latestPrice;
        minted = (assets * PRECISION) / price;
        require(minted > 0, "dust");
        Position storage p = positions[msg.sender];
        p.shares += minted;
        p.entryRound = currentRound;
        totalShares += minted;
        emit RoundEntered(msg.sender, currentRound, assets, minted);
        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
    }

    function exitRound(uint256 shares) external returns (uint256 value) {
        require(shares > 0, "zero");
        _rollForward();
        require(latestPrice > 0, "no round closed");
        Position storage p = positions[msg.sender];
        require(p.shares >= shares, "insufficient");
        value = (shares * latestPrice) / PRECISION;
        p.shares -= shares;
        totalShares -= shares;
        p.claimable += value;
        emit RoundExited(msg.sender, currentRound, shares, value);
    }

    function claimPayout() external returns (uint256 amount) {
        Position storage p = positions[msg.sender];
        amount = p.claimable;
        require(amount > 0, "none");
        p.claimable = 0;
        emit PayoutClaimed(msg.sender, amount);
        require(asset.transfer(msg.sender, amount), "xfer");
    }
}
