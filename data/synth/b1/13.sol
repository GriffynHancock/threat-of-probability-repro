// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title PerSecondBonds
/// @notice Time-locked bonds. A global per-second index accrues yield on every bond
///         unit; each bond snapshots the index when its principal changes.
contract PerSecondBonds {
    uint256 private constant SCALE = 1e18;

    struct Bond {
        uint128 principal;
        uint64 unlockAt;
        uint64 lastTouch;
        uint256 index;
        uint256 earned;
    }

    IERC20 public immutable token;
    address public immutable issuer;
    uint256 public ratePerSecond;
    uint256 public globalIndex;
    uint256 public lastTick;
    uint256 public totalPrincipal;
    uint256 public budget;

    mapping(address => Bond) public bonds;

    event Bonded(address indexed holder, uint256 amount, uint64 unlockAt);
    event Unbonded(address indexed holder, uint256 amount);
    event Collected(address indexed holder, uint256 amount);

    constructor(IERC20 _token, uint256 _ratePerSecond) {
        token = _token;
        issuer = msg.sender;
        ratePerSecond = _ratePerSecond;
        lastTick = block.timestamp;
    }

    function fundBudget(uint256 amount) external {
        require(msg.sender == issuer, "issuer");
        budget += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
    }

    function _tick() internal {
        uint256 elapsed = block.timestamp - lastTick;
        lastTick = block.timestamp;
        if (elapsed == 0 || totalPrincipal == 0) return;
        globalIndex += ratePerSecond * elapsed;
    }

    function _settleBond(Bond storage b) internal {
        b.earned += (uint256(b.principal) * (globalIndex - b.index)) / SCALE;
        b.index = globalIndex;
        b.lastTouch = uint64(block.timestamp);
    }

    function bond(uint256 amount, uint64 lockSeconds) external {
        require(amount > 0, "zero");
        _tick();
        Bond storage b = bonds[msg.sender];
        _settleBond(b);
        b.principal += uint128(amount);
        b.unlockAt = uint64(block.timestamp) + lockSeconds;
        totalPrincipal += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Bonded(msg.sender, amount, b.unlockAt);
    }

    function unbond(uint256 amount) external {
        _tick();
        Bond storage b = bonds[msg.sender];
        require(block.timestamp >= b.unlockAt, "locked");
        _settleBond(b);
        require(amount <= b.principal, "principal");
        b.principal -= uint128(amount);
        totalPrincipal -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit Unbonded(msg.sender, amount);
    }

    function collect() external returns (uint256 owed) {
        _tick();
        Bond storage b = bonds[msg.sender];
        _settleBond(b);
        owed = b.earned;
        require(owed <= budget, "budget");
        b.earned = 0;
        budget -= owed;
        require(token.transfer(msg.sender, owed), "transfer");
        emit Collected(msg.sender, owed);
    }
}
