// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// ============================================================================
//  Subscription pool: subscribe with a minimum ticket, rewards split pro rata.
// ============================================================================
interface IERC20 {
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
}

contract SubscriptionPool {
    struct Subscriber {
        uint amount;
        uint rewardDebt;
        uint accrued;
    }

    uint constant ACC = 1e18;

    IERC20 public subToken;
    IERC20 public yieldToken;
    address public operator;
    uint public minTicket;
    uint public maxTicket;
    uint public yieldPerSecond;
    uint public lastCatch;
    uint public accYieldPerShare;
    uint public poolSize;
    bool public open = true;

    mapping(address => Subscriber) public subscribers;

    event Subscribed(address indexed who, uint amount);
    event Cancelled(address indexed who, uint amount);
    event YieldPaid(address indexed who, uint amount);

    modifier onlyOperator() {
        require(msg.sender == operator, "Subscription: operator only");
        _;
    }

    modifier whenOpen() {
        require(open, "Subscription: closed");
        _;
    }

    constructor(IERC20 _sub, IERC20 _yield, uint _min, uint _max, uint _yieldPerSecond) {
        require(_min <= _max, "Subscription: bad bounds");
        subToken = _sub;
        yieldToken = _yield;
        minTicket = _min;
        maxTicket = _max;
        yieldPerSecond = _yieldPerSecond;
        lastCatch = block.timestamp;
        operator = msg.sender;
    }

    // Settlement helper: catches the yield index up to the current timestamp.
    function _catchUpPool(address _who) internal {
        if (block.timestamp > lastCatch && poolSize > 0) {
            accYieldPerShare += (block.timestamp - lastCatch) * yieldPerSecond * ACC / poolSize;
        }
        lastCatch = block.timestamp;
        if (_who != address(0)) {
            Subscriber storage s = subscribers[_who];
            s.accrued += s.amount * accYieldPerShare / ACC - s.rewardDebt;
            s.rewardDebt = s.amount * accYieldPerShare / ACC;
        }
    }

    function subscribe(uint _amount) external whenOpen {
        require(_amount >= minTicket && _amount <= maxTicket, "Subscription: ticket out of range");
        _catchUpPool(msg.sender);
        Subscriber storage s = subscribers[msg.sender];
        s.amount += _amount;
        require(s.amount <= maxTicket, "Subscription: over max");
        poolSize += _amount;
        s.rewardDebt = s.amount * accYieldPerShare / ACC;
        require(subToken.transferFrom(msg.sender, address(this), _amount), "Subscription: in");
        emit Subscribed(msg.sender, _amount);
    }

    function cancel(uint _amount) external {
        Subscriber storage s = subscribers[msg.sender];
        require(s.amount >= _amount, "Subscription: short");
        _catchUpPool(msg.sender);
        s.amount -= _amount;
        poolSize -= _amount;
        s.rewardDebt = s.amount * accYieldPerShare / ACC;
        require(subToken.transfer(msg.sender, _amount), "Subscription: out");
        emit Cancelled(msg.sender, _amount);
    }

    function collect() external {
        _catchUpPool(msg.sender);
        Subscriber storage s = subscribers[msg.sender];
        uint owed = s.accrued;
        s.accrued = 0;
        if (owed > 0) {
            require(yieldToken.transfer(msg.sender, owed), "Subscription: yield");
            emit YieldPaid(msg.sender, owed);
        }
    }

    function setOpen(bool _open) external onlyOperator {
        open = _open;
    }
}
