// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Plain loyalty balance. Points accrue on-demand from balance x elapsed time.
contract LoyaltyBalance {
    error NothingToRedeem();
    error InsufficientBalance(uint256 have, uint256 want);

    uint256 private constant PRECISION = 1e18;
    uint256 public constant DAY = 1 days;
    uint256 public constant POINTS_PER_TOKEN_DAY = 1e16;

    IERC20 public immutable token;

    struct Account {
        uint256 balance;
        uint256 points;
        uint256 lastTs;
    }
    mapping(address => Account) public accounts;

    event Enrolled(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event PointsRedeemed(address indexed user, uint256 points);

    constructor(IERC20 _token) {
        token = _token;
    }

    /// @dev Realises points owed since the last touch, at the balance held over that interval.
    function _realizeLoyalty(address who) internal {
        Account storage a = accounts[who];
        if (a.lastTs != 0 && a.balance > 0) {
            uint256 dt = block.timestamp - a.lastTs;
            a.points += (a.balance * POINTS_PER_TOKEN_DAY * dt) / (DAY * PRECISION);
        }
        a.lastTs = block.timestamp;
    }

    function enroll(uint256 amount) external {
        _realizeLoyalty(msg.sender);
        Account storage a = accounts[msg.sender];
        a.balance += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit Enrolled(msg.sender, amount);
    }

    function withdrawBalance(uint256 amount) external {
        _realizeLoyalty(msg.sender);
        Account storage a = accounts[msg.sender];
        if (a.balance < amount) revert InsufficientBalance(a.balance, amount);
        a.balance -= amount;
        require(token.transfer(msg.sender, amount), "push failed");
        emit Withdrawn(msg.sender, amount);
    }

    function redeemPoints(uint256 amount) external {
        _realizeLoyalty(msg.sender);
        Account storage a = accounts[msg.sender];
        if (amount == 0 || a.points < amount) revert NothingToRedeem();
        a.points -= amount;
        require(token.transfer(msg.sender, amount), "push failed");
        emit PointsRedeemed(msg.sender, amount);
    }
}
