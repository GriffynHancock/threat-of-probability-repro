// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// Exchange-rate market. Suppliers hold share units; the exchange rate rises as
/// borrowers pay interest. Borrowing is restricted to admin-approved borrowers.
contract CTokenMarket {
    uint256 private constant SCALE = 1e18;
    uint256 private constant BASE_RATE_PER_SEC = 6e8;
    uint256 private constant SLOPE_PER_SEC = 2e9;
    uint256 private constant RESERVE_FACTOR = 1e17;

    IERC20 public immutable underlying;
    address public immutable admin;

    uint256 public totalShares;
    uint256 public cash;
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public borrowIndex = SCALE;
    uint256 public accrualTimestamp;

    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public isBorrower;
    mapping(address => uint256) public borrowPrincipal;

    event Minted(address indexed who, uint256 amount, uint256 shares);
    event Redeemed(address indexed who, uint256 shares, uint256 amount);
    event Borrowed(address indexed who, uint256 amount);
    event Repaid(address indexed who, uint256 amount);
    event Accrued(uint256 interest, uint256 reserves);

    constructor(IERC20 _underlying) {
        underlying = _underlying;
        admin = msg.sender;
        accrualTimestamp = block.timestamp;
    }

    function setBorrower(address who, bool allowed) external {
        require(msg.sender == admin, "not admin");
        isBorrower[who] = allowed;
    }

    /// @notice Current utilisation, scaled by 1e18.
    function utilization() public view returns (uint256) {
        uint256 denom = cash + totalBorrows;
        if (denom == 0) return 0;
        return (totalBorrows * SCALE) / denom;
    }

    function borrowRatePerSec() public view returns (uint256) {
        return BASE_RATE_PER_SEC + (utilization() * SLOPE_PER_SEC) / SCALE;
    }

    /// @notice Underlying per share, scaled by 1e18.
    function exchangeRate() public view returns (uint256) {
        if (totalShares == 0) return SCALE;
        return ((cash + totalBorrows - totalReserves) * SCALE) / totalShares;
    }

    function _updateIndex() internal {
        uint256 dt = block.timestamp - accrualTimestamp;
        accrualTimestamp = block.timestamp;
        if (dt == 0 || totalBorrows == 0) return;
        uint256 rate = borrowRatePerSec() * dt;
        uint256 interest = (totalBorrows * rate) / SCALE;
        totalBorrows += interest;
        totalReserves += (interest * RESERVE_FACTOR) / SCALE;
        borrowIndex += (borrowIndex * rate) / SCALE;
        emit Accrued(interest, totalReserves);
    }

    function _debtOf(address who) internal view returns (uint256) {
        return (borrowPrincipal[who] * borrowIndex) / SCALE;
    }

    function mint(uint256 amount) external {
        require(amount > 0, "zero");
        _updateIndex();
        uint256 shares = (amount * SCALE) / exchangeRate();
        require(shares > 0, "dust");
        balanceOf[msg.sender] += shares;
        totalShares += shares;
        cash += amount;
        require(underlying.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Minted(msg.sender, amount, shares);
    }

    function redeem(uint256 shares) external {
        require(shares > 0 && shares <= balanceOf[msg.sender], "shares");
        _updateIndex();
        uint256 amount = (shares * exchangeRate()) / SCALE;
        require(amount <= cash, "cash");
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;
        cash -= amount;
        require(underlying.transfer(msg.sender, amount), "transfer");
        emit Redeemed(msg.sender, shares, amount);
    }

    function borrow(uint256 amount) external {
        require(isBorrower[msg.sender], "not borrower");
        _updateIndex();
        require(amount > 0 && amount <= cash, "amount");
        borrowPrincipal[msg.sender] += (amount * SCALE) / borrowIndex;
        totalBorrows += amount;
        cash -= amount;
        require(underlying.transfer(msg.sender, amount), "transfer");
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        _updateIndex();
        uint256 owed = _debtOf(msg.sender);
        uint256 pay = amount > owed ? owed : amount;
        borrowPrincipal[msg.sender] -= (pay * SCALE) / borrowIndex;
        totalBorrows -= pay;
        cash += pay;
        require(underlying.transferFrom(msg.sender, address(this), pay), "transferFrom");
        emit Repaid(msg.sender, pay);
    }
}
