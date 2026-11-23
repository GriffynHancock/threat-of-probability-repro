// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Inline SafeMath, 0.6-era copy
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
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

//////////////////////////////////////////////////////////////////////////////
// Orchard - multi-pool. Anyone can stake on behalf of a beneficiary; the
// beneficiary's rewards accrue from the moment of the stake.
//////////////////////////////////////////////////////////////////////////////
contract Orchard {
    using SafeMath for uint256;

    struct Tree {
        uint256 staked;
        uint256 rewardDebt;
        uint256 harvestable;
    }

    struct Grove {
        IERC20 stakeToken;
        uint256 weight;
        uint256 lastStream;
        uint256 streamIndex;
    }

    uint256 private constant ONE = 1e12;

    IERC20 public fruit;
    address public gardener;
    uint256 public fruitRate;
    uint256 public weightTotal;

    Grove[] public groves;
    mapping(uint256 => mapping(address => Tree)) public trees;

    event Staked(address indexed payer, address indexed beneficiary, uint256 indexed gid, uint256 amount);
    event Unstaked(address indexed owner, uint256 indexed gid, uint256 amount);
    event FruitPicked(address indexed owner, uint256 indexed gid, uint256 amount);

    modifier onlyGardener() {
        require(msg.sender == gardener, "Orchard: gardener only");
        _;
    }

    constructor(IERC20 _fruit, uint256 _fruitRate) {
        fruit = _fruit;
        fruitRate = _fruitRate;
        gardener = msg.sender;
    }

    function plantGrove(uint256 _weight, IERC20 _stake) external onlyGardener {
        weightTotal = weightTotal.add(_weight);
        groves.push(Grove(_stake, _weight, block.timestamp, 0));
    }

    // Settlement helper: advances the stream index and credits the beneficiary.
    function _settleStreams(uint256 _gid, address _who) internal {
        Grove storage g = groves[_gid];
        uint256 supply = g.stakeToken.balanceOf(address(this));
        uint256 dt = block.timestamp.sub(g.lastStream);
        if (dt > 0 && supply > 0 && weightTotal > 0) {
            uint256 minted = dt.mul(fruitRate).mul(g.weight).div(weightTotal);
            g.streamIndex = g.streamIndex.add(minted.mul(ONE).div(supply));
        }
        g.lastStream = block.timestamp;

        Tree storage t = trees[_gid][_who];
        t.harvestable = t.harvestable.add(t.staked.mul(g.streamIndex.sub(t.rewardDebt)).div(ONE));
        t.rewardDebt = g.streamIndex;
    }

    // Anyone may fund a stake for a beneficiary (e.g. a treasury top-up).
    function stakeFor(uint256 _gid, address _beneficiary, uint256 _amount) external {
        require(_amount > 0, "Orchard: zero");
        _settleStreams(_gid, _beneficiary);
        Tree storage t = trees[_gid][_beneficiary];
        t.staked = t.staked.add(_amount);
        require(groves[_gid].stakeToken.transferFrom(msg.sender, address(this), _amount), "Orchard: in");
        emit Staked(msg.sender, _beneficiary, _gid, _amount);
    }

    function unstake(uint256 _gid, uint256 _amount) external {
        Tree storage t = trees[_gid][msg.sender];
        require(t.staked >= _amount, "Orchard: short");
        _settleStreams(_gid, msg.sender);
        t.staked = t.staked.sub(_amount);
        require(groves[_gid].stakeToken.transfer(msg.sender, _amount), "Orchard: out");
        emit Unstaked(msg.sender, _gid, _amount);
    }

    function pickFruit(uint256 _gid) external {
        _settleStreams(_gid, msg.sender);
        Tree storage t = trees[_gid][msg.sender];
        uint256 picked = t.harvestable;
        if (picked > 0) {
            t.harvestable = 0;
            require(fruit.transfer(msg.sender, picked), "Orchard: fruit");
            emit FruitPicked(msg.sender, _gid, picked);
        }
    }
}
