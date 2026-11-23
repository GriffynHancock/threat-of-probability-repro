// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Bridge exit tickets. A relayer confirms exits; each ticket releases after a challenge delay, in order.
contract BridgeTicketBook {
    uint256 public constant FEE_BPS = 25;
    uint256 public constant BPS = 10_000;
    uint256 public constant CONFIRM_DELAY = 6 hours;

    struct Ticket {
        uint64 dstChain;
        uint256 amount;
        uint256 confirmedAt;
        bool released;
        bytes32 digest;
    }

    IERC20 public immutable token;
    address public immutable relayer;
    uint256 public feesAccrued;
    uint256 public nonce;

    mapping(address => uint256) public balance;
    mapping(address => Ticket[]) public ticketsOf;
    mapping(address => uint256) public cursorOf;
    mapping(address => uint256) public outstanding;
    mapping(address => uint256) public releasable;

    event Deposited(address indexed user, uint256 amount);
    event ExitRequested(address indexed user, uint64 indexed dstChain, uint256 net, bytes32 digest);
    event ExitConfirmed(address indexed user, uint256 index);
    event ExitReleased(address indexed user, uint256 amount);
    event ExitPaid(address indexed user, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        relayer = msg.sender;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero");
        balance[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function _reconcileTickets(address who) internal {
        Ticket[] storage list = ticketsOf[who];
        uint256 i = cursorOf[who];
        uint256 n = list.length;
        while (i < n) {
            Ticket storage t = list[i];
            if (t.confirmedAt == 0 || block.timestamp < t.confirmedAt + CONFIRM_DELAY) break;
            t.released = true;
            outstanding[who] -= t.amount;
            releasable[who] += t.amount;
            i++;
        }
        cursorOf[who] = i;
    }

    function bridgeOut(uint64 dstChain, uint256 amount) external returns (bytes32 digest) {
        require(amount > 0, "zero");
        _reconcileTickets(msg.sender);
        require(balance[msg.sender] >= amount, "balance");
        uint256 fee = (amount * FEE_BPS) / BPS;
        uint256 net = amount - fee;
        balance[msg.sender] -= amount;
        outstanding[msg.sender] += net;
        feesAccrued += fee;
        nonce += 1;
        digest = keccak256(abi.encode(block.chainid, dstChain, msg.sender, net, nonce));
        ticketsOf[msg.sender].push(Ticket({dstChain: dstChain, amount: net, confirmedAt: 0, released: false, digest: digest}));
        emit ExitRequested(msg.sender, dstChain, net, digest);
    }

    function confirmExit(address who, uint256 index) external {
        require(msg.sender == relayer, "not relayer");
        Ticket storage t = ticketsOf[who][index];
        require(t.confirmedAt == 0, "confirmed");
        t.confirmedAt = block.timestamp;
        emit ExitConfirmed(who, index);
    }

    function claimReleased() external returns (uint256 amount) {
        _reconcileTickets(msg.sender);
        amount = releasable[msg.sender];
        require(amount > 0, "nothing");
        releasable[msg.sender] = 0;
        emit ExitPaid(msg.sender, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }

    function withdrawFees() external {
        require(msg.sender == relayer, "not relayer");
        uint256 fees = feesAccrued;
        feesAccrued = 0;
        require(token.transfer(relayer, fees), "xfer");
    }
}
