// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// ============================================================================
// CappedHarvestPool - single pool with a hard cap on total contributions.
// Reward rate is recalculated whenever the pool size changes.
// ============================================================================
interface IERC20 {
    function balanceOf(address account) external view returns (uint);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

contract CappedHarvestPool {
    struct Contributor {
        uint contributed;
        uint rewardDebt;
        uint claimable;
    }

    uint constant SCALE = 1e12;

    IERC20 public contribToken;
    IERC20 public rewardToken;
    address public keeper;
    uint public totalCap;
    uint public poolRate;
    uint public rateUpdatedAt;
    uint public accPerUnit;
    uint public totalContributed;

    mapping(address => Contributor) public contributors;

    event Contributed(address indexed who, uint amount, uint total);
    event Reclaimed(address indexed who, uint amount);
    event Harvested(address indexed who, uint amount);

    modifier onlyKeeper() {
        require(msg.sender == keeper, "CappedHarvest: keeper only");
        _;
    }

    constructor(IERC20 _contrib, IERC20 _reward, uint _cap, uint _rate) {
        contribToken = _contrib;
        rewardToken = _reward;
        totalCap = _cap;
        poolRate = _rate;
        rateUpdatedAt = block.timestamp;
        keeper = msg.sender;
    }

    // Settlement helper: pays the global index up to now at the current rate.
    function _recalcAccRate() internal {
        uint elapsed = block.timestamp - rateUpdatedAt;
        if (elapsed > 0 && totalContributed > 0) {
            accPerUnit += elapsed * poolRate * SCALE / totalContributed;
        }
        rateUpdatedAt = block.timestamp;
    }

    function _settleContributor(address _who) internal {
        Contributor storage c = contributors[_who];
        c.claimable += c.contributed * accPerUnit / SCALE - c.rewardDebt;
        c.rewardDebt = c.contributed * accPerUnit / SCALE;
    }

    function contribute(uint _amount) external {
        require(_amount > 0, "CappedHarvest: zero");
        require(totalContributed + _amount <= totalCap, "CappedHarvest: cap reached");
        _recalcAccRate();
        _settleContributor(msg.sender);
        Contributor storage c = contributors[msg.sender];
        c.contributed += _amount;
        totalContributed += _amount;
        c.rewardDebt = c.contributed * accPerUnit / SCALE;
        require(contribToken.transferFrom(msg.sender, address(this), _amount), "CappedHarvest: in");
        emit Contributed(msg.sender, _amount, totalContributed);
    }

    function reclaim(uint _amount) external {
        Contributor storage c = contributors[msg.sender];
        require(c.contributed >= _amount, "CappedHarvest: short");
        _recalcAccRate();
        _settleContributor(msg.sender);
        c.contributed -= _amount;
        totalContributed -= _amount;
        c.rewardDebt = c.contributed * accPerUnit / SCALE;
        require(contribToken.transfer(msg.sender, _amount), "CappedHarvest: out");
        emit Reclaimed(msg.sender, _amount);
    }

    function harvest() external {
        _recalcAccRate();
        _settleContributor(msg.sender);
        Contributor storage c = contributors[msg.sender];
        uint amount = c.claimable;
        c.claimable = 0;
        if (amount > 0) {
            require(rewardToken.transfer(msg.sender, amount), "CappedHarvest: reward");
            emit Harvested(msg.sender, amount);
        }
    }

    function setRate(uint _rate) external onlyKeeper {
        _recalcAccRate();
        poolRate = _rate;
    }

    function setCap(uint _cap) external onlyKeeper {
        require(_cap >= totalContributed, "CappedHarvest: below current total");
        totalCap = _cap;
    }
}
