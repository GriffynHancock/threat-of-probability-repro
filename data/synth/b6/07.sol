// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

error InsufficientBalance(uint256 have, uint256 want);
error NotHolder();
error NotSettled();
error AlreadyClaimed();

/// @notice FIFO exit queue. Liquidity is returned by the operator; tickets settle in order as cash arrives.
contract ExitTicketQueue {
    struct Ticket {
        address holder;
        uint256 amount;
        bool settled;
    }

    IERC20 public immutable token;
    address public immutable operator;

    Ticket[] public tickets;
    uint256 public head;
    uint256 public liquidity;
    uint256 public reservedForClaims;
    uint256 public pendingTickets;
    uint256 public totalDeposits;

    mapping(address => uint256) public balanceOf;

    event QueueDeposited(address indexed user, uint256 amount);
    event ExitRequested(address indexed holder, uint256 ticketId, uint256 amount);
    event ExitSettled(uint256 indexed ticketId, uint256 amount);
    event ExitClaimed(uint256 indexed ticketId, uint256 amount);
    event CapitalDeployed(address indexed to, uint256 amount);
    event LiquidityReturned(uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        operator = msg.sender;
    }

    function _settleQueueHead() internal {
        uint256 n = tickets.length;
        while (head < n) {
            Ticket storage t = tickets[head];
            if (t.amount > liquidity - reservedForClaims) break;
            reservedForClaims += t.amount;
            pendingTickets -= t.amount;
            t.settled = true;
            emit ExitSettled(head, t.amount);
            head++;
        }
    }

    function queueDeposit(uint256 amount) external {
        require(amount > 0, "zero");
        _settleQueueHead();
        balanceOf[msg.sender] += amount;
        totalDeposits += amount;
        liquidity += amount;
        emit QueueDeposited(msg.sender, amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function requestExit(uint256 amount) external returns (uint256 ticketId) {
        require(amount > 0, "zero");
        _settleQueueHead();
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        balanceOf[msg.sender] -= amount;
        totalDeposits -= amount;
        pendingTickets += amount;
        tickets.push(Ticket({holder: msg.sender, amount: amount, settled: false}));
        ticketId = tickets.length - 1;
        emit ExitRequested(msg.sender, ticketId, amount);
    }

    function deployCapital(address to, uint256 amount) external {
        require(msg.sender == operator, "not operator");
        require(amount <= liquidity - reservedForClaims, "not free");
        liquidity -= amount;
        emit CapitalDeployed(to, amount);
        require(token.transfer(to, amount), "xfer");
    }

    function returnLiquidity(uint256 amount) external {
        require(msg.sender == operator, "not operator");
        liquidity += amount;
        emit LiquidityReturned(amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        _settleQueueHead();
    }

    function claimTicket(uint256 ticketId) external returns (uint256 amount) {
        Ticket storage t = tickets[ticketId];
        if (t.holder != msg.sender) revert NotHolder();
        if (!t.settled) revert NotSettled();
        amount = t.amount;
        if (amount == 0) revert AlreadyClaimed();
        t.amount = 0;
        reservedForClaims -= amount;
        liquidity -= amount;
        emit ExitClaimed(ticketId, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }
}
