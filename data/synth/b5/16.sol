// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

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

// ===========================================================================
// EpochCommitPool - multi-pool where commitments are bucketed into epochs.
// Rewards for an epoch are fixed once the epoch closes.
// ===========================================================================
contract EpochCommitPool {
    using SafeMath for uint256;

    struct Pool {
        IERC20 token;
        uint256 epochLength;
        uint256 currentEpoch;
        uint256 epochStart;
        uint256 perEpochReward;
        uint256 accPerShare;
        uint256 committed;
    }

    struct Commitment {
        uint256 amount;
        uint256 rewardDebt;
        uint256 owed;
    }

    uint256 private constant SCALE = 1e18;

    IERC20 public reward;
    address public admin;
    Pool[] public pools;
    mapping(uint256 => mapping(address => Commitment)) public commitments;

    event PoolAdded(uint256 indexed pid, address token, uint256 epochLength);
    event Committed(address indexed who, uint256 indexed pid, uint256 amount);
    event Released(address indexed who, uint256 indexed pid, uint256 amount);
    event EpochRolled(uint256 indexed pid, uint256 epoch);

    modifier onlyAdmin() {
        require(msg.sender == admin, "EpochCommit: admin only");
        _;
    }

    constructor(IERC20 _reward) {
        reward = _reward;
        admin = msg.sender;
    }

    function addPool(IERC20 _token, uint256 _epochLength, uint256 _perEpochReward) external onlyAdmin {
        require(_epochLength > 0, "EpochCommit: epoch length");
        pools.push(Pool({
            token: _token,
            epochLength: _epochLength,
            currentEpoch: 0,
            epochStart: block.timestamp,
            perEpochReward: _perEpochReward,
            accPerShare: 0,
            committed: 0
        }));
        emit PoolAdded(pools.length - 1, address(_token), _epochLength);
    }

    // Settlement helper: closes any finished epochs and folds their reward into the index.
    function _syncEpoch(uint256 _pid) internal {
        Pool storage p = pools[_pid];
        while (block.timestamp >= p.epochStart.add(p.epochLength)) {
            if (p.committed > 0) {
                p.accPerShare = p.accPerShare.add(p.perEpochReward.mul(SCALE).div(p.committed));
            }
            p.epochStart = p.epochStart.add(p.epochLength);
            p.currentEpoch = p.currentEpoch.add(1);
            emit EpochRolled(_pid, p.currentEpoch);
        }
    }

    function _settleCommitment(uint256 _pid, address _who) internal {
        Commitment storage c = commitments[_pid][_who];
        c.owed = c.owed.add(c.amount.mul(pools[_pid].accPerShare).div(SCALE).sub(c.rewardDebt));
        c.rewardDebt = c.amount.mul(pools[_pid].accPerShare).div(SCALE);
    }

    function commit(uint256 _pid, uint256 _amount) external {
        require(_amount > 0, "EpochCommit: zero");
        _syncEpoch(_pid);
        _settleCommitment(_pid, msg.sender);
        Commitment storage c = commitments[_pid][msg.sender];
        c.amount = c.amount.add(_amount);
        pools[_pid].committed = pools[_pid].committed.add(_amount);
        c.rewardDebt = c.amount.mul(pools[_pid].accPerShare).div(SCALE);
        require(pools[_pid].token.transferFrom(msg.sender, address(this), _amount), "EpochCommit: in");
        emit Committed(msg.sender, _pid, _amount);
    }

    function release(uint256 _pid, uint256 _amount) external {
        Commitment storage c = commitments[_pid][msg.sender];
        require(c.amount >= _amount, "EpochCommit: short");
        _syncEpoch(_pid);
        _settleCommitment(_pid, msg.sender);
        c.amount = c.amount.sub(_amount);
        pools[_pid].committed = pools[_pid].committed.sub(_amount);
        c.rewardDebt = c.amount.mul(pools[_pid].accPerShare).div(SCALE);
        require(pools[_pid].token.transfer(msg.sender, _amount), "EpochCommit: out");
        emit Released(msg.sender, _pid, _amount);
    }

    function harvest(uint256 _pid) external {
        _syncEpoch(_pid);
        _settleCommitment(_pid, msg.sender);
        Commitment storage c = commitments[_pid][msg.sender];
        uint256 owed = c.owed;
        c.owed = 0;
        if (owed > 0) {
            require(reward.transfer(msg.sender, owed), "EpochCommit: reward");
        }
    }
}
