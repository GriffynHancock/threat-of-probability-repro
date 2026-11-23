// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title RateCurveBorrowPool
/// @notice Liquidity pool with a per-second rate curve. The admin draws a strategy loan
///         whose interest is shared by suppliers through a supply index. Pausable.
contract RateCurveBorrowPool {
    uint256 private constant SCALE = 1e18;
    uint256 private constant RATE_FLOOR = 3e8;
    uint256 private constant RATE_CEIL = 9e9;

    enum Status { Active, Paused }

    struct Supplier {
        uint256 shares;
        uint256 costAtEntry;
    }

    error Paused_();
    error NotAdmin();
    error TooLittle();
    error OverDrawn(uint256 requested, uint256 cash);

    IERC20 public immutable asset;
    address public immutable admin;
    Status public status;

    uint256 public supplyIndex = SCALE;
    uint256 public lastAccrual;
    uint256 public totalShares;
    uint256 public cash;
    uint256 public drawn;

    mapping(address => Supplier) public suppliers;

    event Provided(address indexed who, uint256 amount, uint256 shares);
    event Removed(address indexed who, uint256 shares, uint256 amount);
    event Drawn(uint256 amount);
    event Returned(uint256 amount);
    event StatusSet(Status status);

    constructor(IERC20 _asset) {
        asset = _asset;
        admin = msg.sender;
        lastAccrual = block.timestamp;
    }

    function setStatus(Status s) external {
        if (msg.sender != admin) revert NotAdmin();
        status = s;
        emit StatusSet(s);
    }

    function rate() public view returns (uint256) {
        if (cash + drawn == 0) return RATE_FLOOR;
        uint256 u = (drawn * SCALE) / (cash + drawn);
        uint256 r = RATE_FLOOR + (u * (RATE_CEIL - RATE_FLOOR)) / SCALE;
        return r;
    }

    /// @dev Advances the supply index by the curve rate over elapsed time.
    function _catchUp() internal {
        uint256 elapsed = block.timestamp - lastAccrual;
        lastAccrual = block.timestamp;
        if (elapsed == 0 || drawn == 0 || totalShares == 0) return;
        uint256 growth = (rate() * elapsed);
        uint256 interest = (drawn * growth) / SCALE;
        drawn += interest;
        supplyIndex += (supplyIndex * growth) / SCALE;
    }

    function provideLiquidity(uint256 amount) external {
        if (status == Status.Paused) revert Paused_();
        if (amount == 0) revert TooLittle();
        _catchUp();
        Supplier storage s = suppliers[msg.sender];
        uint256 minted = (amount * SCALE) / supplyIndex;
        s.shares += minted;
        s.costAtEntry += amount;
        totalShares += minted;
        cash += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Provided(msg.sender, amount, minted);
    }

    function removeLiquidity(uint256 shares) external {
        if (status == Status.Paused) revert Paused_();
        _catchUp();
        Supplier storage s = suppliers[msg.sender];
        if (shares == 0 || shares > s.shares) revert TooLittle();
        uint256 out = (shares * supplyIndex) / SCALE;
        if (out > cash) revert OverDrawn(out, cash);
        s.shares -= shares;
        totalShares -= shares;
        cash -= out;
        require(asset.transfer(msg.sender, out), "transfer");
        emit Removed(msg.sender, shares, out);
    }

    function draw(uint256 amount) external {
        if (msg.sender != admin) revert NotAdmin();
        _catchUp();
        if (amount > cash) revert OverDrawn(amount, cash);
        cash -= amount;
        drawn += amount;
        require(asset.transfer(msg.sender, amount), "transfer");
        emit Drawn(amount);
    }

    function repayDraw(uint256 amount) external {
        if (msg.sender != admin) revert NotAdmin();
        _catchUp();
        if (amount > drawn) revert OverDrawn(amount, drawn);
        drawn -= amount;
        cash += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Returned(amount);
    }
}
