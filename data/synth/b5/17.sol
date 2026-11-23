// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// ============================================================================
// PledgeHub - multi-pool pledge farm. Each pool has a weight multiplier; a
// pledger's shares are amount * weight, and total shares are rebalanced when
// the pool's weight changes.
// ============================================================================
interface IERC20 {
    function balanceOf(address account) external view returns (uint);
    function transfer(address to, uint amount) external returns (bool);
    function transferFrom(address from, address to, uint amount) external returns (bool);
}

contract PledgeHub {
    struct PoolInfo {
        IERC20 token;
        uint weight;
        uint sharesTotal;
        uint lastAccrual;
        uint accIndex;
    }

    struct PledgeInfo {
        uint pledged;
        uint shares;
        uint index;
        uint accrued;
    }

    uint constant ONE = 1e18;

    IERC20 public rewardToken;
    address public chairman;
    uint public emissionPerSecond;
    uint public weightSum;

    PoolInfo[] public pools;
    mapping(uint => mapping(address => PledgeInfo)) public pledges;

    event Pledged(address indexed who, uint indexed pid, uint amount);
    event Unpledged(address indexed who, uint indexed pid, uint amount);
    event Earned(address indexed who, uint indexed pid, uint amount);
    event WeightChanged(uint indexed pid, uint oldWeight, uint newWeight);

    modifier onlyChairman() {
        require(msg.sender == chairman, "PledgeHub: chairman only");
        _;
    }

    constructor(IERC20 _reward, uint _emissionPerSecond) {
        rewardToken = _reward;
        emissionPerSecond = _emissionPerSecond;
        chairman = msg.sender;
    }

    function addPool(IERC20 _token, uint _weight) external onlyChairman {
        weightSum += _weight;
        pools.push(PoolInfo(_token, _weight, 0, block.timestamp, 0));
    }

    // Settlement helper: accrues the pool index and rebalances nothing else.
    function _rebalanceShares(uint _pid) internal {
        PoolInfo storage p = pools[_pid];
        if (block.timestamp > p.lastAccrual && p.sharesTotal > 0 && weightSum > 0) {
            uint earned = (block.timestamp - p.lastAccrual) * emissionPerSecond * p.weight / weightSum;
            p.accIndex += earned * ONE / p.sharesTotal;
        }
        p.lastAccrual = block.timestamp;
    }

    function _creditPledge(uint _pid, address _who) internal {
        PledgeInfo storage pl = pledges[_pid][_who];
        pl.accrued += pl.shares * (pools[_pid].accIndex - pl.index) / ONE;
        pl.index = pools[_pid].accIndex;
    }

    function pledge(uint _pid, uint _amount) external {
        require(_amount > 0, "PledgeHub: zero");
        _rebalanceShares(_pid);
        _creditPledge(_pid, msg.sender);
        PoolInfo storage p = pools[_pid];
        PledgeInfo storage pl = pledges[_pid][msg.sender];
        uint newShares = _amount * p.weight;
        pl.pledged += _amount;
        pl.shares += newShares;
        p.sharesTotal += newShares;
        require(p.token.transferFrom(msg.sender, address(this), _amount), "PledgeHub: in");
        emit Pledged(msg.sender, _pid, _amount);
    }

    function unpledge(uint _pid, uint _amount) external {
        PledgeInfo storage pl = pledges[_pid][msg.sender];
        require(pl.pledged >= _amount, "PledgeHub: short");
        _rebalanceShares(_pid);
        _creditPledge(_pid, msg.sender);
        PoolInfo storage p = pools[_pid];
        uint dropShares = _amount * p.weight;
        pl.pledged -= _amount;
        pl.shares -= dropShares;
        p.sharesTotal -= dropShares;
        require(p.token.transfer(msg.sender, _amount), "PledgeHub: out");
        emit Unpledged(msg.sender, _pid, _amount);
    }

    function collect(uint _pid) external {
        _rebalanceShares(_pid);
        _creditPledge(_pid, msg.sender);
        PledgeInfo storage pl = pledges[_pid][msg.sender];
        uint amount = pl.accrued;
        pl.accrued = 0;
        if (amount > 0) {
            require(rewardToken.transfer(msg.sender, amount), "PledgeHub: reward");
            emit Earned(msg.sender, _pid, amount);
        }
    }

    function setWeight(uint _pid, uint _newWeight) external onlyChairman {
        _rebalanceShares(_pid);
        uint oldWeight = pools[_pid].weight;
        weightSum = weightSum - oldWeight + _newWeight;
        pools[_pid].weight = _newWeight;
        emit WeightChanged(_pid, oldWeight, _newWeight);
    }
}
