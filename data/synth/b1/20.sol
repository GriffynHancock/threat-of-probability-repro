// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title StreamingContributions
/// @notice Each contribution is kept as its own position in an array. Yield streams per
///         position at a fixed per-second rate; reconciliation walks the user's positions.
contract StreamingContributions {
    uint256 private constant SCALE = 1e18;
    uint256 private constant RATE_PER_SECOND = 4e9;
    uint256 private constant MAX_POSITIONS = 64;

    struct Position {
        uint256 amount;
        uint256 lastSettled;
    }

    IERC20 public immutable token;
    address public immutable host;
    uint256 public totalContributed;
    uint256 public reserve;

    mapping(address => Position[]) public positions;
    mapping(address => uint256) public contributedBy;
    mapping(address => uint256) public pendingYield;

    event Contributed(address indexed who, uint256 amount, uint256 index);
    event PositionClosed(address indexed who, uint256 index, uint256 amount);
    event YieldClaimed(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        host = msg.sender;
    }

    function fundReserve(uint256 amount) external {
        require(msg.sender == host, "host");
        reserve += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
    }

    /// @dev Streams yield into pendingYield for every open position of `who`.
    function _reconcile(address who) internal {
        Position[] storage ps = positions[who];
        uint256 owed;
        for (uint256 i = 0; i < ps.length; i++) {
            Position storage p = ps[i];
            owed += (p.amount * RATE_PER_SECOND * (block.timestamp - p.lastSettled)) / SCALE;
            p.lastSettled = block.timestamp;
        }
        pendingYield[who] += owed;
    }

    function contribute(uint256 amount) external {
        require(amount > 0, "zero");
        require(positions[msg.sender].length < MAX_POSITIONS, "too many");
        _reconcile(msg.sender);
        positions[msg.sender].push(Position(amount, block.timestamp));
        contributedBy[msg.sender] += amount;
        totalContributed += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Contributed(msg.sender, amount, positions[msg.sender].length - 1);
    }

    function closePosition(uint256 index) external {
        _reconcile(msg.sender);
        Position[] storage ps = positions[msg.sender];
        require(index < ps.length, "index");
        uint256 amount = ps[index].amount;
        ps[index] = ps[ps.length - 1];
        ps.pop();
        contributedBy[msg.sender] -= amount;
        totalContributed -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit PositionClosed(msg.sender, index, amount);
    }

    function claimYield() external returns (uint256 owed) {
        _reconcile(msg.sender);
        owed = pendingYield[msg.sender];
        require(owed <= reserve, "reserve");
        pendingYield[msg.sender] = 0;
        reserve -= owed;
        require(token.transfer(msg.sender, owed), "transfer");
        emit YieldClaimed(msg.sender, owed);
    }
}
