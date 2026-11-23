// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Play-to-earn pool. Players buy tickets; tickets accrue play yield per second.
contract PlayPool {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable token;
    uint256 public immutable yieldPerTicketSecond;
    uint256 public immutable ticketPrice;

    uint256 public totalTickets;

    struct Player {
        uint256 tickets;
        uint256 earned;
        uint256 lastTs;
    }
    mapping(address => Player) public players;

    event Joined(address indexed player, uint256 tickets);
    event Left(address indexed player, uint256 tickets);
    event YieldClaimed(address indexed player, uint256 amount);

    constructor(IERC20 _token, uint256 _yield, uint256 _ticketPrice) {
        token = _token;
        yieldPerTicketSecond = _yield;
        ticketPrice = _ticketPrice;
    }

    function _collectPlayYield(address who) internal {
        Player storage p = players[who];
        if (p.lastTs != 0 && p.tickets > 0) {
            uint256 dt = block.timestamp - p.lastTs;
            p.earned += (p.tickets * yieldPerTicketSecond * dt) / PRECISION;
        }
        p.lastTs = block.timestamp;
    }

    function joinPool(uint256 tickets) external {
        require(tickets > 0, "zero tickets");
        _collectPlayYield(msg.sender);
        Player storage p = players[msg.sender];
        p.tickets += tickets;
        totalTickets += tickets;
        uint256 cost = (tickets * ticketPrice) / PRECISION;
        require(token.transferFrom(msg.sender, address(this), cost), "pull failed");
        emit Joined(msg.sender, tickets);
    }

    function leavePool(uint256 tickets) external {
        _collectPlayYield(msg.sender);
        Player storage p = players[msg.sender];
        require(p.tickets >= tickets, "not enough tickets");
        p.tickets -= tickets;
        totalTickets -= tickets;
        uint256 refund = (tickets * ticketPrice) / PRECISION;
        require(token.transfer(msg.sender, refund), "refund failed");
        emit Left(msg.sender, tickets);
    }

    function claimPlayYield() external {
        _collectPlayYield(msg.sender);
        Player storage p = players[msg.sender];
        uint256 amount = p.earned;
        require(amount > 0, "nothing earned");
        p.earned = 0;
        require(token.transfer(msg.sender, amount), "payout failed");
        emit YieldClaimed(msg.sender, amount);
    }
}
