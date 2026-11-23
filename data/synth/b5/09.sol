// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//==========================================================================
// File: contracts/libraries/SafeMath.sol
//==========================================================================
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: add");
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: sub");
        return a - b;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: mul");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: div");
        return a / b;
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

//==========================================================================
// DualRewardFarm - pays two reward tokens from one LP pool.
// Each reward has its own per-share index; both are settled together.
//==========================================================================
contract DualRewardFarm {
    using SafeMath for uint256;

    struct Position {
        uint256 amount;
        uint256 debtA;
        uint256 debtB;
        uint256 owedA;
        uint256 owedB;
    }

    uint256 private constant SCALE = 1e18;

    IERC20 public lp;
    IERC20 public rewardA;
    IERC20 public rewardB;
    address public steward;

    uint256 public rateA;
    uint256 public rateB;
    uint256 public lastSync;
    uint256 public indexA;
    uint256 public indexB;
    uint256 public staked;

    mapping(address => Position) public positions;

    event LpDeposited(address indexed who, uint256 amount);
    event LpWithdrawn(address indexed who, uint256 amount);
    event Claimed(address indexed who, uint256 a, uint256 b);

    modifier onlySteward() {
        require(msg.sender == steward, "DualRewardFarm: not steward");
        _;
    }

    constructor(IERC20 _lp, IERC20 _a, IERC20 _b, uint256 _rateA, uint256 _rateB) {
        lp = _lp;
        rewardA = _a;
        rewardB = _b;
        rateA = _rateA;
        rateB = _rateB;
        lastSync = block.timestamp;
        steward = msg.sender;
    }

    // Settlement helper: advances both reward indices.
    function _syncAccounts() internal {
        uint256 elapsed = block.timestamp.sub(lastSync);
        lastSync = block.timestamp;
        if (elapsed == 0 || staked == 0) {
            return;
        }
        indexA = indexA.add(elapsed.mul(rateA).mul(SCALE).div(staked));
        indexB = indexB.add(elapsed.mul(rateB).mul(SCALE).div(staked));
    }

    function _settle(address _who) internal {
        Position storage p = positions[_who];
        p.owedA = p.owedA.add(p.amount.mul(indexA.sub(p.debtA)).div(SCALE));
        p.owedB = p.owedB.add(p.amount.mul(indexB.sub(p.debtB)).div(SCALE));
        p.debtA = indexA;
        p.debtB = indexB;
    }

    function depositLP(uint256 _amount) external {
        require(_amount > 0, "DualRewardFarm: zero");
        _syncAccounts();
        _settle(msg.sender);
        Position storage position = positions[msg.sender];
        position.amount = position.amount.add(_amount);
        staked = staked.add(_amount);
        require(lp.transferFrom(msg.sender, address(this), _amount), "DualRewardFarm: lp in");
        emit LpDeposited(msg.sender, _amount);
    }

    function withdrawLP(uint256 _amount) external {
        Position storage position = positions[msg.sender];
        require(position.amount >= _amount, "DualRewardFarm: short");
        _syncAccounts();
        _settle(msg.sender);
        position.amount = position.amount.sub(_amount);
        staked = staked.sub(_amount);
        require(lp.transfer(msg.sender, _amount), "DualRewardFarm: lp out");
        emit LpWithdrawn(msg.sender, _amount);
    }

    function claim() external {
        _syncAccounts();
        _settle(msg.sender);
        Position storage p = positions[msg.sender];
        uint256 a = p.owedA;
        uint256 b = p.owedB;
        p.owedA = 0;
        p.owedB = 0;
        if (a > 0) require(rewardA.transfer(msg.sender, a), "DualRewardFarm: A");
        if (b > 0) require(rewardB.transfer(msg.sender, b), "DualRewardFarm: B");
        emit Claimed(msg.sender, a, b);
    }

    function setRates(uint256 _a, uint256 _b) external onlySteward {
        _syncAccounts();
        rateA = _a;
        rateB = _b;
    }
}
