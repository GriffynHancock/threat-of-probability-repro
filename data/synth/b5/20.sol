// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ---------------------------------------------------------------------------
// Inline SafeMath
// ---------------------------------------------------------------------------
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

// ============================================================================
// HarvestLedger - multi-pool farm with a manual reentrancy lock (2020 idiom),
// a per-pool deposit ceiling, and a separate collect path for rewards.
// ============================================================================
contract HarvestLedger {
    using SafeMath for uint256;

    struct Ledger {
        uint256 amount;
        uint256 rewardDebt;
        uint256 rewardOwed;
    }

    struct Field {
        IERC20 token;
        uint256 weight;
        uint256 lastHarvest;
        uint256 harvestIndex;
        uint256 ceiling;
        uint256 total;
    }

    uint256 private constant ACC = 1e12;

    IERC20 public harvestToken;
    address public steward;
    uint256 public harvestPerSecond;
    uint256 public weightSum;
    uint256 private _status = 1;

    Field[] public fields;
    mapping(uint256 => mapping(address => Ledger)) public ledgers;

    event FieldOpened(uint256 indexed fid, address token, uint256 ceiling);
    event Added(address indexed who, uint256 indexed fid, uint256 amount);
    event Removed(address indexed who, uint256 indexed fid, uint256 amount);
    event Collected(address indexed who, uint256 indexed fid, uint256 amount);

    modifier nonReentrant() {
        require(_status == 1, "HarvestLedger: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }

    modifier onlySteward() {
        require(msg.sender == steward, "HarvestLedger: steward only");
        _;
    }

    constructor(IERC20 _harvest, uint256 _harvestPerSecond) {
        harvestToken = _harvest;
        harvestPerSecond = _harvestPerSecond;
        steward = msg.sender;
    }

    function openField(IERC20 _token, uint256 _weight, uint256 _ceiling) external onlySteward {
        weightSum = weightSum.add(_weight);
        fields.push(Field(_token, _weight, block.timestamp, 0, _ceiling, 0));
        emit FieldOpened(fields.length - 1, address(_token), _ceiling);
    }

    // Settlement helper: advances the harvest index of one field.
    function _collectRewards(uint256 _fid) internal {
        Field storage f = fields[_fid];
        if (block.timestamp <= f.lastHarvest) return;
        if (f.total == 0 || weightSum == 0) {
            f.lastHarvest = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp.sub(f.lastHarvest);
        uint256 grown = dt.mul(harvestPerSecond).mul(f.weight).div(weightSum);
        f.harvestIndex = f.harvestIndex.add(grown.mul(ACC).div(f.total));
        f.lastHarvest = block.timestamp;
    }

    function addStake(uint256 _fid, uint256 _amount) external nonReentrant {
        Field storage f = fields[_fid];
        require(f.total.add(_amount) <= f.ceiling, "HarvestLedger: ceiling");
        _collectRewards(_fid);
        Ledger storage l = ledgers[_fid][msg.sender];
        l.rewardOwed = l.rewardOwed.add(l.amount.mul(f.harvestIndex).div(ACC).sub(l.rewardDebt));
        l.amount = l.amount.add(_amount);
        f.total = f.total.add(_amount);
        l.rewardDebt = l.amount.mul(f.harvestIndex).div(ACC);
        require(f.token.transferFrom(msg.sender, address(this), _amount), "HarvestLedger: in");
        emit Added(msg.sender, _fid, _amount);
    }

    function removeStake(uint256 _fid, uint256 _amount) external nonReentrant {
        Ledger storage l = ledgers[_fid][msg.sender];
        require(l.amount >= _amount, "HarvestLedger: short");
        _collectRewards(_fid);
        Field storage f = fields[_fid];
        l.rewardOwed = l.rewardOwed.add(l.amount.mul(f.harvestIndex).div(ACC).sub(l.rewardDebt));
        l.amount = l.amount.sub(_amount);
        f.total = f.total.sub(_amount);
        l.rewardDebt = l.amount.mul(f.harvestIndex).div(ACC);
        require(f.token.transfer(msg.sender, _amount), "HarvestLedger: out");
        emit Removed(msg.sender, _fid, _amount);
    }

    function collect(uint256 _fid) external nonReentrant {
        _collectRewards(_fid);
        Field storage f = fields[_fid];
        Ledger storage l = ledgers[_fid][msg.sender];
        l.rewardOwed = l.rewardOwed.add(l.amount.mul(f.harvestIndex).div(ACC).sub(l.rewardDebt));
        l.rewardDebt = l.amount.mul(f.harvestIndex).div(ACC);
        uint256 owed = l.rewardOwed;
        l.rewardOwed = 0;
        if (owed > 0) {
            require(harvestToken.transfer(msg.sender, owed), "HarvestLedger: harvest");
            emit Collected(msg.sender, _fid, owed);
        }
    }
}
