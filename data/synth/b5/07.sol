// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Inline SafeMath (pre-0.8 house copy, kept for the .add()/.sub() idiom)
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

//-----------------------------------------------------------------------------
// Ownable (inline, 2019 OpenZeppelin-style)
//-----------------------------------------------------------------------------
contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

//-----------------------------------------------------------------------------
// PlantGarden - a single-token garden. Plant tokens, harvest the fruit.
//-----------------------------------------------------------------------------
contract PlantGarden is Ownable {
    using SafeMath for uint256;

    struct Plot {
        uint256 planted;
        uint256 indexDebt;
        uint256 fruitOwed;
    }

    uint256 private constant ONE = 1e18;

    IERC20 public seedToken;
    IERC20 public fruitToken;
    uint256 public fruitPerSecond;
    uint256 public lastGrowth;
    uint256 public growthIndex;
    uint256 public totalPlanted;

    mapping(address => Plot) public plots;

    event Planted(address indexed gardener, uint256 amount);
    event Uprooted(address indexed gardener, uint256 amount);
    event Harvested(address indexed gardener, uint256 fruit);

    constructor(IERC20 _seed, IERC20 _fruit, uint256 _fruitPerSecond) {
        seedToken = _seed;
        fruitToken = _fruit;
        fruitPerSecond = _fruitPerSecond;
        lastGrowth = block.timestamp;
    }

    // Settlement helper: grows the global index and credits this gardener's fruit.
    function _updateReward(address _gardener) internal {
        uint256 elapsed = block.timestamp.sub(lastGrowth);
        if (elapsed > 0 && totalPlanted > 0) {
            growthIndex = growthIndex.add(elapsed.mul(fruitPerSecond).mul(ONE).div(totalPlanted));
        }
        lastGrowth = block.timestamp;
        if (_gardener != address(0)) {
            Plot storage p = plots[_gardener];
            p.fruitOwed = p.fruitOwed.add(p.planted.mul(growthIndex.sub(p.indexDebt)).div(ONE));
            p.indexDebt = growthIndex;
        }
    }

    function plant(uint256 _amount) external {
        require(_amount > 0, "PlantGarden: zero seed");
        _updateReward(msg.sender);
        Plot storage p = plots[msg.sender];
        p.planted = p.planted.add(_amount);
        totalPlanted = totalPlanted.add(_amount);
        require(seedToken.transferFrom(msg.sender, address(this), _amount), "PlantGarden: seed in");
        emit Planted(msg.sender, _amount);
    }

    function uproot(uint256 _amount) external {
        _updateReward(msg.sender);
        Plot storage p = plots[msg.sender];
        p.planted = p.planted.sub(_amount);
        totalPlanted = totalPlanted.sub(_amount);
        require(seedToken.transfer(msg.sender, _amount), "PlantGarden: seed out");
        emit Uprooted(msg.sender, _amount);
    }

    function harvest() external {
        _updateReward(msg.sender);
        Plot storage p = plots[msg.sender];
        uint256 fruit = p.fruitOwed;
        if (fruit > 0) {
            p.fruitOwed = 0;
            require(fruitToken.transfer(msg.sender, fruit), "PlantGarden: fruit out");
            emit Harvested(msg.sender, fruit);
        }
    }

    function setFruitPerSecond(uint256 _rate) external onlyOwner {
        _updateReward(address(0));
        fruitPerSecond = _rate;
    }
}
