// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title FixedTermDeposits
/// @notice Users lock principal for one of three fixed terms. Simple interest accrues
///         per lock at the term's APR and is realised for matured or active locks.
contract FixedTermDeposits {
    uint256 private constant SCALE = 1e18;
    uint256 private constant YEAR = 365 days;
    uint256 public constant TERM_COUNT = 3;

    struct Lock {
        uint128 principal;
        uint64 unlockAt;
        uint64 realizedAt;
    }

    IERC20 public immutable token;
    address public immutable owner;
    uint256 public yieldReserve;

    mapping(address => mapping(uint256 => Lock)) public locks;
    mapping(address => uint256) public claimableYield;

    event Opened(address indexed user, uint256 termId, uint256 amount);
    event Closed(address indexed user, uint256 termId, uint256 amount);
    event YieldClaimed(address indexed user, uint256 amount);
    event YieldFunded(uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        owner = msg.sender;
    }

    function fundYield(uint256 amount) external {
        require(msg.sender == owner, "not owner");
        yieldReserve += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit YieldFunded(amount);
    }

    function termSeconds(uint256 termId) public pure returns (uint256) {
        if (termId == 0) return 30 days;
        if (termId == 1) return 90 days;
        return 365 days;
    }

    function termApr(uint256 termId) public pure returns (uint256) {
        if (termId == 0) return 4e16;
        if (termId == 1) return 6e16;
        return 9e16;
    }

    /// @dev Realises simple interest on every lock owned by `user`, up to the earlier of
    ///      now and each lock's unlock time.
    function _realizeYield(address user) internal {
        for (uint256 t = 0; t < TERM_COUNT; t++) {
            Lock storage l = locks[user][t];
            uint256 end = block.timestamp < l.unlockAt ? block.timestamp : l.unlockAt;
            if (end <= l.realizedAt || l.principal == 0) {
                l.realizedAt = uint64(end > l.realizedAt ? end : l.realizedAt);
                continue;
            }
            uint256 earned = (uint256(l.principal) * termApr(t) * (end - l.realizedAt)) / (SCALE * YEAR);
            claimableYield[user] += earned;
            l.realizedAt = uint64(end);
        }
    }

    function openPosition(uint256 termId, uint256 amount) external {
        require(termId < TERM_COUNT, "term");
        require(amount > 0, "zero");
        _realizeYield(msg.sender);
        Lock storage l = locks[msg.sender][termId];
        l.principal += uint128(amount);
        l.realizedAt = uint64(block.timestamp);
        l.unlockAt = uint64(block.timestamp + termSeconds(termId));
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Opened(msg.sender, termId, amount);
    }

    function closePosition(uint256 termId) external {
        require(termId < TERM_COUNT, "term");
        _realizeYield(msg.sender);
        Lock storage l = locks[msg.sender][termId];
        require(block.timestamp >= l.unlockAt, "locked");
        uint256 amount = l.principal;
        require(amount > 0, "empty");
        l.principal = 0;
        require(token.transfer(msg.sender, amount), "transfer");
        emit Closed(msg.sender, termId, amount);
    }

    function claimYield() external returns (uint256 amount) {
        _realizeYield(msg.sender);
        amount = claimableYield[msg.sender];
        require(amount <= yieldReserve, "reserve");
        claimableYield[msg.sender] = 0;
        yieldReserve -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit YieldClaimed(msg.sender, amount);
    }
}
