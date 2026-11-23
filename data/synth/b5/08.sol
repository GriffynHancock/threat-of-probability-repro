// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ==========================================================================
//  EnterFarm  -  the "enter / exit" farm from the Sushi-era forks
// ==========================================================================
interface IERC20 {
    function balanceOf(address) external view returns (uint);
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
}

contract EnterFarm {
    struct Position {
        uint amount;
        uint debt;
    }

    struct Pool {
        IERC20 token;
        uint weight;
        uint lastTouch;
        uint accCakePerShare;
    }

    uint constant PREC = 1e12;

    IERC20 public cake;
    address public deployer;
    uint public cakePerSecond;
    uint public weightSum;

    Pool[] public pools;
    mapping(uint => mapping(address => Position)) public positions;

    event Entered(address indexed who, uint indexed pid, uint amount);
    event Exited(address indexed who, uint indexed pid, uint amount);
    event Reaped(address indexed who, uint indexed pid, uint cake);

    constructor(IERC20 _cake, uint _cakePerSecond) {
        cake = _cake;
        cakePerSecond = _cakePerSecond;
        deployer = msg.sender;
    }

    function addPool(uint _weight, IERC20 _token) external {
        require(msg.sender == deployer, "EnterFarm: deployer only");
        weightSum += _weight;
        pools.push(Pool(_token, _weight, block.timestamp, 0));
    }

    // Settlement helper: brings one pool's cake index to the current block time.
    function updatePoolRewards(uint _pid) public {
        Pool storage p = pools[_pid];
        if (block.timestamp <= p.lastTouch) return;
        uint staked = p.token.balanceOf(address(this));
        if (staked == 0 || weightSum == 0) {
            p.lastTouch = block.timestamp;
            return;
        }
        uint elapsed = block.timestamp - p.lastTouch;
        uint minted = elapsed * cakePerSecond * p.weight / weightSum;
        p.accCakePerShare += minted * PREC / staked;
        p.lastTouch = block.timestamp;
    }

    function enter(uint _pid, uint _amount) external {
        updatePoolRewards(_pid);
        Position storage pos = positions[_pid][msg.sender];
        uint reaped = 0;
        if (pos.amount > 0) {
            reaped = pos.amount * pools[_pid].accCakePerShare / PREC - pos.debt;
        }
        pos.amount += _amount;
        pos.debt = pos.amount * pools[_pid].accCakePerShare / PREC;
        if (reaped > 0) {
            require(cake.transfer(msg.sender, reaped), "EnterFarm: cake");
            emit Reaped(msg.sender, _pid, reaped);
        }
        if (_amount > 0) {
            require(pools[_pid].token.transferFrom(msg.sender, address(this), _amount), "EnterFarm: token in");
        }
        emit Entered(msg.sender, _pid, _amount);
    }

    function exit(uint _pid, uint _amount) external {
        Position storage pos = positions[_pid][msg.sender];
        require(pos.amount >= _amount, "EnterFarm: exceeds stake");
        updatePoolRewards(_pid);
        uint reaped = pos.amount * pools[_pid].accCakePerShare / PREC - pos.debt;
        pos.amount -= _amount;
        pos.debt = pos.amount * pools[_pid].accCakePerShare / PREC;
        if (reaped > 0) {
            require(cake.transfer(msg.sender, reaped), "EnterFarm: cake");
            emit Reaped(msg.sender, _pid, reaped);
        }
        require(pools[_pid].token.transfer(msg.sender, _amount), "EnterFarm: token out");
        emit Exited(msg.sender, _pid, _amount);
    }

    function emergencyExit(uint _pid) external {
        Position storage pos = positions[_pid][msg.sender];
        uint amount = pos.amount;
        pos.amount = 0;
        pos.debt = 0;
        require(pools[_pid].token.transfer(msg.sender, amount), "EnterFarm: token out");
        emit Exited(msg.sender, _pid, amount);
    }
}
