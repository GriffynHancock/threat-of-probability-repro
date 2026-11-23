// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// ============================================================================
// File: contracts/interfaces/IERC20.sol
// ============================================================================
interface IERC20 {
    function balanceOf(address account) external view returns (uint);
    function transfer(address to, uint amount) external returns (bool);
    function transferFrom(address from, address to, uint amount) external returns (bool);
}

// ============================================================================
// BakeOven - multi-pool bakery with a pause switch for emergencies.
// Pausing blocks new deposits only; withdrawals always remain available.
// ============================================================================
contract BakeOven {
    struct Pan {
        IERC20 flour;
        uint weight;
        uint lastBake;
        uint riseIndex;
    }

    struct Loaf {
        uint amount;
        uint riseDebt;
        uint crust;
    }

    uint constant RISE_SCALE = 1e12;

    IERC20 public bread;
    address public baker;
    bool public paused;
    uint public breadPerSecond;
    uint public weightTotal;

    Pan[] public pans;
    mapping(uint => mapping(address => Loaf)) public loaves;

    event Kneaded(address indexed who, uint indexed pan, uint amount);
    event Proofed(address indexed who, uint indexed pan, uint amount);
    event Baked(address indexed who, uint indexed pan, uint amount);
    event PausedSet(bool status);

    modifier onlyBaker() {
        require(msg.sender == baker, "BakeOven: baker only");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "BakeOven: paused");
        _;
    }

    constructor(IERC20 _bread, uint _breadPerSecond) {
        bread = _bread;
        breadPerSecond = _breadPerSecond;
        baker = msg.sender;
    }

    function addPan(IERC20 _flour, uint _weight) external onlyBaker {
        weightTotal += _weight;
        pans.push(Pan({flour: _flour, weight: _weight, lastBake: block.timestamp, riseIndex: 0}));
    }

    // Settlement helper: raises the pan's rise index for the time since last bake.
    function _refreshIndex(uint _pan) internal {
        Pan storage p = pans[_pan];
        if (block.timestamp <= p.lastBake) return;
        uint flourSupply = p.flour.balanceOf(address(this));
        if (flourSupply == 0 || weightTotal == 0) {
            p.lastBake = block.timestamp;
            return;
        }
        uint dt = block.timestamp - p.lastBake;
        p.riseIndex += dt * breadPerSecond * p.weight * RISE_SCALE / (weightTotal * flourSupply);
        p.lastBake = block.timestamp;
    }

    function bakeIn(uint _pan, uint _amount) external whenNotPaused {
        _refreshIndex(_pan);
        Loaf storage l = loaves[_pan][msg.sender];
        uint crust = 0;
        if (l.amount > 0) {
            crust = l.amount * pans[_pan].riseIndex / RISE_SCALE - l.riseDebt;
        }
        l.amount += _amount;
        l.riseDebt = l.amount * pans[_pan].riseIndex / RISE_SCALE;
        l.crust += crust;
        require(pans[_pan].flour.transferFrom(msg.sender, address(this), _amount), "BakeOven: flour in");
        emit Kneaded(msg.sender, _pan, _amount);
    }

    function pullOut(uint _pan, uint _amount) external {
        Loaf storage l = loaves[_pan][msg.sender];
        require(l.amount >= _amount, "BakeOven: not enough");
        _refreshIndex(_pan);
        uint crust = l.amount * pans[_pan].riseIndex / RISE_SCALE - l.riseDebt;
        l.amount -= _amount;
        l.riseDebt = l.amount * pans[_pan].riseIndex / RISE_SCALE;
        l.crust += crust;
        require(pans[_pan].flour.transfer(msg.sender, _amount), "BakeOven: flour out");
        emit Proofed(msg.sender, _pan, _amount);
    }

    function collectCrust(uint _pan) external {
        _refreshIndex(_pan);
        Loaf storage l = loaves[_pan][msg.sender];
        uint owed = l.crust + (l.amount * pans[_pan].riseIndex / RISE_SCALE - l.riseDebt);
        l.crust = 0;
        l.riseDebt = l.amount * pans[_pan].riseIndex / RISE_SCALE;
        if (owed > 0) {
            require(bread.transfer(msg.sender, owed), "BakeOven: bread");
            emit Baked(msg.sender, _pan, owed);
        }
    }

    function setPaused(bool _paused) external onlyBaker {
        paused = _paused;
        emit PausedSet(_paused);
    }
}
