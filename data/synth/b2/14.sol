// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Per-epoch rewards with checkpointed balances. Each balance change
/// writes an (epoch, value) checkpoint for the holder and for the total. An
/// epoch's reward is split by end-of-epoch balances, and a holder claims
/// closed epochs in order from its own cursor.
contract EpochCheckpointRewards {
    struct Checkpoint {
        uint256 epoch;
        uint256 value;
    }

    uint256 public immutable epochLength;
    uint256 public immutable genesis;

    IERC20 public immutable stake;
    IERC20 public immutable reward;

    uint256 public totalShares;
    Checkpoint[] internal totalHistory;

    mapping(uint256 => uint256) public epochReward;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public cursor;
    mapping(address => Checkpoint[]) internal userHistory;

    event EpochFunded(uint256 indexed epoch, uint256 amount);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(IERC20 _stake, IERC20 _reward, uint256 _epochLength) {
        require(_epochLength > 0, "zero length");
        stake = _stake;
        reward = _reward;
        epochLength = _epochLength;
        genesis = block.timestamp;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / epochLength;
    }

    function fundEpoch(uint256 epoch, uint256 amount) external {
        require(epoch > currentEpoch(), "epoch already open");
        require(reward.transferFrom(msg.sender, address(this), amount), "transfer failed");
        epochReward[epoch] += amount;
        emit EpochFunded(epoch, amount);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        _snapshotThrough(msg.sender);
        sharesOf[msg.sender] += amount;
        totalShares += amount;
        _writeCheckpoints(msg.sender);
        require(stake.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount <= sharesOf[msg.sender], "insufficient");
        _snapshotThrough(msg.sender);
        sharesOf[msg.sender] -= amount;
        totalShares -= amount;
        _writeCheckpoints(msg.sender);
        require(stake.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claims every closed epoch since the caller's cursor.
    function claim() external {
        uint256 nowEpoch = currentEpoch();
        uint256 owed;
        for (uint256 e = cursor[msg.sender]; e < nowEpoch; ++e) {
            uint256 total = _valueAt(totalHistory, e);
            if (total == 0) continue;
            uint256 mine = _valueAt(userHistory[msg.sender], e);
            owed += epochReward[e] * mine / total;
        }
        cursor[msg.sender] = nowEpoch;
        if (owed > 0) {
            require(reward.transfer(msg.sender, owed), "transfer failed");
            emit Claimed(msg.sender, owed);
        }
    }

    /// @dev Pins the holder's pre-change balance at the current epoch so that
    /// history before the change is never rewritten by it.
    function _snapshotThrough(address who) internal {
        _pushOrUpdate(userHistory[who], currentEpoch(), sharesOf[who]);
    }

    function _writeCheckpoints(address who) internal {
        uint256 e = currentEpoch();
        _pushOrUpdate(userHistory[who], e, sharesOf[who]);
        _pushOrUpdate(totalHistory, e, totalShares);
    }

    function _pushOrUpdate(Checkpoint[] storage h, uint256 e, uint256 v) internal {
        uint256 n = h.length;
        if (n > 0 && h[n - 1].epoch == e) {
            h[n - 1].value = v;
        } else {
            h.push(Checkpoint({epoch: e, value: v}));
        }
    }

    /// @dev Value in force at the end of epoch `e`: the latest checkpoint at or before `e`.
    function _valueAt(Checkpoint[] storage h, uint256 e) internal view returns (uint256) {
        for (uint256 i = h.length; i > 0; --i) {
            if (h[i - 1].epoch <= e) return h[i - 1].value;
        }
        return 0;
    }
}
