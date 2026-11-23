// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ExchangeRateLender
/// @notice Holders subscribe cash for units priced at a stored exchange rate. The treasury
///         lends cash out; the loan book accrues a fixed APR, which lifts the rate.
contract ExchangeRateLender {
    uint256 private constant SCALE = 1e18;
    uint256 private constant BPS = 10000;
    uint256 private constant APR_BPS = 800;
    uint256 private constant YEAR = 365 days;

    error ZeroValue();
    error NotTreasury();
    error InsufficientCash(uint256 requested, uint256 available);

    IERC20 public immutable asset;
    address public immutable treasury;

    uint256 public storedRate = SCALE;
    uint256 public lastRefresh;
    uint256 public cash;
    uint256 public loanBook;
    uint256 public totalUnits;

    mapping(address => uint256) public unitsOf;

    event Subscribed(address indexed who, uint256 amount, uint256 units);
    event Redeemed(address indexed who, uint256 units, uint256 amount);
    event LentOut(uint256 amount);
    event LoanReturned(uint256 amount);

    constructor(IERC20 _asset) {
        asset = _asset;
        treasury = msg.sender;
        lastRefresh = block.timestamp;
    }

    /// @dev Accrues the loan book, then recomputes the stored exchange rate.
    function _refreshExchangeRate() internal {
        uint256 dt = block.timestamp - lastRefresh;
        lastRefresh = block.timestamp;
        if (dt > 0 && loanBook > 0) {
            loanBook += (loanBook * APR_BPS * dt) / (BPS * YEAR);
        }
        storedRate = totalUnits == 0 ? SCALE : ((cash + loanBook) * SCALE) / totalUnits;
    }

    function subscribe(uint256 amount) external {
        if (amount == 0) revert ZeroValue();
        _refreshExchangeRate();
        uint256 units = (amount * SCALE) / storedRate;
        unitsOf[msg.sender] += units;
        totalUnits += units;
        cash += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Subscribed(msg.sender, amount, units);
    }

    function redeemUnits(uint256 units) external {
        _refreshExchangeRate();
        require(units > 0 && units <= unitsOf[msg.sender], "units");
        uint256 amount = (units * storedRate) / SCALE;
        if (amount > cash) revert InsufficientCash(amount, cash);
        unitsOf[msg.sender] -= units;
        totalUnits -= units;
        cash -= amount;
        require(asset.transfer(msg.sender, amount), "transfer");
        emit Redeemed(msg.sender, units, amount);
    }

    function withdrawAll() external returns (uint256 amount) {
        _refreshExchangeRate();
        uint256 units = unitsOf[msg.sender];
        require(units > 0, "nothing");
        amount = (units * storedRate) / SCALE;
        if (amount > cash) revert InsufficientCash(amount, cash);
        unitsOf[msg.sender] = 0;
        totalUnits -= units;
        cash -= amount;
        require(asset.transfer(msg.sender, amount), "transfer");
        emit Redeemed(msg.sender, units, amount);
    }

    function lendOut(uint256 amount) external {
        if (msg.sender != treasury) revert NotTreasury();
        _refreshExchangeRate();
        if (amount > cash) revert InsufficientCash(amount, cash);
        cash -= amount;
        loanBook += amount;
        require(asset.transfer(msg.sender, amount), "transfer");
        emit LentOut(amount);
    }

    function returnLoan(uint256 amount) external {
        _refreshExchangeRate();
        require(amount <= loanBook, "over-repaid");
        loanBook -= amount;
        cash += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit LoanReturned(amount);
    }
}
