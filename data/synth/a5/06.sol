// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// Auto-compounding vault. Yield accrues against principal and can be folded
/// back into principal by the holder or, in batches, by a keeper.
contract AutoCompoundVault {
    error NothingToCompound();
    error BelowMinimum(uint256 got, uint256 min);
    error InsufficientPrincipal(uint256 have, uint256 want);
    error NotKeeper();

    uint256 public constant PRECISION = 1e18;
    uint256 public constant MIN_COMPOUND = 1e6;

    IERC20 public immutable asset;
    address public immutable keeper;

    uint256 public yieldPerSecond;
    uint256 public lastTickTime;
    uint256 public yieldIndex;
    uint256 public totalPrincipal;

    mapping(address => uint256) public principal;
    mapping(address => uint256) public indexSeen;
    mapping(address => uint256) public pendingYield;

    event Deposit(address indexed who, uint256 amount);
    event Withdraw(address indexed who, uint256 amount);
    event Compounded(address indexed who, uint256 amount, uint256 newPrincipal);
    event Funded(address indexed from, uint256 amount);

    constructor(IERC20 _asset, uint256 _yieldPerSecond, address _keeper) {
        asset = _asset;
        yieldPerSecond = _yieldPerSecond;
        keeper = _keeper;
        lastTickTime = block.timestamp;
    }

    /// @notice Anyone may top up the yield reserve. The vault must hold enough
    ///         of `asset` to cover principal plus yield.
    function fund(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "fund failed");
        emit Funded(msg.sender, amount);
    }

    function deposit(uint256 amount) external {
        _bringCurrent(msg.sender);
        require(amount > 0, "zero");
        require(asset.transferFrom(msg.sender, address(this), amount), "pull failed");
        principal[msg.sender] += amount;
        totalPrincipal += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        _bringCurrent(msg.sender);
        uint256 have = principal[msg.sender];
        if (have < amount) revert InsufficientPrincipal(have, amount);
        principal[msg.sender] = have - amount;
        totalPrincipal -= amount;
        require(asset.transfer(msg.sender, amount), "send failed");
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Reinvest the caller's pending yield into principal.
    function compound() external {
        uint256 y = _reinvest(msg.sender);
        if (y == 0) revert NothingToCompound();
        if (y < MIN_COMPOUND) revert BelowMinimum(y, MIN_COMPOUND);
    }

    /// @notice Keeper batch: reinvest for many accounts. Accounts with no
    ///         yield are skipped.
    function compoundFor(address[] calldata users) external {
        if (msg.sender != keeper) revert NotKeeper();
        for (uint256 i = 0; i < users.length; i++) {
            _reinvest(users[i]);
        }
    }

    /// @dev Moves pending yield into principal. Brings the account's index
    ///      checkpoint current first, so the new principal only earns from now on.
    function _reinvest(address who) internal returns (uint256 y) {
        _bringCurrent(who);
        y = pendingYield[who];
        if (y == 0) return 0;
        pendingYield[who] = 0;
        principal[who] += y;
        totalPrincipal += y;
        emit Compounded(who, y, principal[who]);
    }

    /// @dev Settlement helper. Advances the global index, then freezes the
    ///      account's yield at its existing principal before the checkpoint moves.
    function _bringCurrent(address who) internal {
        _tick();
        uint256 p = principal[who];
        if (p != 0) {
            pendingYield[who] += p * (yieldIndex - indexSeen[who]) / PRECISION;
        }
        indexSeen[who] = yieldIndex;
    }

    function _tick() internal {
        uint256 dt = block.timestamp - lastTickTime;
        lastTickTime = block.timestamp;
        if (dt == 0 || totalPrincipal == 0) return;
        yieldIndex += yieldPerSecond * dt * PRECISION / totalPrincipal;
    }
}
