// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title StreamingPayroll
/// @notice Funders deposit into a worker's stream; value vests continuously at the worker's rate.
contract StreamingPayroll {
    IERC20 public immutable payToken;
    address public immutable owner;

    struct Stream {
        uint256 rate;
        uint256 deposited;
        uint256 vested;
        uint256 paid;
        uint256 lastTick;
    }

    mapping(address => Stream) public streams;
    uint256 public totalDeposited;

    event StreamOpened(address indexed worker, uint256 rate);
    event Funded(address indexed funder, address indexed worker, uint256 amount);
    event Vested(address indexed worker, uint256 amount);
    event Withdrawn(address indexed worker, uint256 amount);

    constructor(IERC20 _token) {
        payToken = _token;
        owner = msg.sender;
    }

    function _accrueStream(address worker) internal {
        Stream storage s = streams[worker];
        if (s.lastTick == 0 || s.rate == 0) {
            s.lastTick = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - s.lastTick;
        uint256 inc = s.rate * elapsed;
        uint256 remaining = s.deposited - s.vested;
        if (inc > remaining) inc = remaining;
        s.vested += inc;
        s.lastTick = block.timestamp;
        emit Vested(worker, inc);
    }

    /// @notice Owner sets a worker's streaming rate (tokens per second).
    function openStream(address worker, uint256 ratePerSecond) external {
        require(msg.sender == owner, "not owner");
        _accrueStream(worker);
        streams[worker].rate = ratePerSecond;
        emit StreamOpened(worker, ratePerSecond);
    }

    /// @notice Fund a worker's stream. Funder pays; value joins the worker's deposit.
    function fundStream(address worker, uint256 amount) external {
        require(amount > 0, "zero amount");
        _accrueStream(worker);
        Stream storage s = streams[worker];
        s.deposited += amount;
        totalDeposited += amount;
        require(payToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Funded(msg.sender, worker, amount);
    }

    /// @notice Withdraw a specific amount of vested tokens.
    function cashOut(uint256 amount) external {
        _accrueStream(msg.sender);
        Stream storage s = streams[msg.sender];
        require(s.vested - s.paid >= amount, "not vested");
        s.paid += amount;
        totalDeposited -= amount;
        require(payToken.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim everything vested so far.
    function drawVested() external {
        _accrueStream(msg.sender);
        Stream storage s = streams[msg.sender];
        uint256 amount = s.vested - s.paid;
        require(amount > 0, "nothing vested");
        s.paid += amount;
        totalDeposited -= amount;
        require(payToken.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }
}
