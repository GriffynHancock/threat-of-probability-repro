// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Boosted LP gauge. A user's working balance is 40% of their base stake plus
// 60% scaled by their share of vote-escrow balance, capped at base stake.
contract VeBoostGauge {
    uint256 private constant Q = 1e18;
    uint256 private constant MIN_BPS = 4000;
    uint256 private constant BPS = 10000;

    struct Stake {
        uint256 base;
        uint256 ve;
        uint256 working;
        uint256 rewardPaid;
        uint256 rewardOwed;
    }

    IERC20 public immutable lp;
    IERC20 public immutable reward;
    address public immutable governance;

    uint256 public totalBase;
    uint256 public totalVe;
    uint256 public totalWorking;
    uint256 public rewardPerWorking;
    uint256 public rewardRatePerSecond;
    uint256 public lastRewardTime;

    mapping(address => Stake) public stakes;

    event Increased(address indexed who, uint256 amount, uint256 working);
    event Decreased(address indexed who, uint256 amount, uint256 working);
    event Harvested(address indexed who, uint256 amount);
    event VeUpdated(address indexed who, uint256 ve);

    constructor(IERC20 _lp, IERC20 _reward, uint256 _ratePerSecond) {
        lp = _lp;
        reward = _reward;
        governance = msg.sender;
        rewardRatePerSecond = _ratePerSecond;
        lastRewardTime = block.timestamp;
    }

    function setVeBalance(address who, uint256 newVe) external {
        require(msg.sender == governance, "not governance");
        _refreshBoost(who);
        totalVe = totalVe - stakes[who].ve + newVe;
        stakes[who].ve = newVe;
        _setWorking(who);
        emit VeUpdated(who, newVe);
    }

    function increase(uint256 amount) external {
        require(amount > 0, "zero amount");
        _refreshBoost(msg.sender);
        Stake storage s = stakes[msg.sender];
        s.base += amount;
        totalBase += amount;
        _setWorking(msg.sender);
        require(lp.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Increased(msg.sender, amount, s.working);
    }

    function decrease(uint256 amount) external {
        Stake storage s = stakes[msg.sender];
        require(amount <= s.base, "insufficient base");
        _refreshBoost(msg.sender);
        s.base -= amount;
        totalBase -= amount;
        _setWorking(msg.sender);
        require(lp.transfer(msg.sender, amount), "transfer failed");
        emit Decreased(msg.sender, amount, s.working);
    }

    function harvest() external {
        _refreshBoost(msg.sender);
        Stake storage s = stakes[msg.sender];
        uint256 owed = s.rewardOwed;
        s.rewardOwed = 0;
        if (owed > 0) {
            require(reward.transfer(msg.sender, owed), "transfer failed");
            emit Harvested(msg.sender, owed);
        }
    }

    /// @dev Accrues global reward per unit of working balance, then credits
    /// the account at its current working balance.
    function _refreshBoost(address who) internal {
        if (block.timestamp > lastRewardTime && totalWorking > 0) {
            rewardPerWorking += (block.timestamp - lastRewardTime) * rewardRatePerSecond * Q / totalWorking;
        }
        lastRewardTime = block.timestamp;
        Stake storage s = stakes[who];
        s.rewardOwed += s.working * (rewardPerWorking - s.rewardPaid) / Q;
        s.rewardPaid = rewardPerWorking;
    }

    /// @dev Recomputes the working balance from base and ve, keeping totalWorking in sync.
    function _setWorking(address who) internal {
        Stake storage s = stakes[who];
        uint256 boosted = s.base * MIN_BPS / BPS;
        if (totalVe > 0) {
            boosted += (s.base * (BPS - MIN_BPS) / BPS) * s.ve / totalVe;
        }
        if (boosted > s.base) boosted = s.base;
        totalWorking = totalWorking - s.working + boosted;
        s.working = boosted;
    }
}
