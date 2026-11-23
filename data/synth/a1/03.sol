// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IToken {
    function transfer(address to, uint256 amt) external returns (bool);
    function transferFrom(address from, address to, uint256 amt) external returns (bool);
}

/// @title EpochFarm
/// @notice Multi-pool farm. Emissions are granted per epoch of EPOCH_BLOCKS blocks.
/// @dev Each pool keeps its own accumulator; positions are keyed by (pid, user).
contract EpochFarm {
    struct PoolInfo {
        IToken stakeToken;
        uint256 emissionPerEpoch;
        uint256 lastEpoch;
        uint256 accPerShare;
        uint256 totalStaked;
    }

    struct Position {
        uint256 amount;
        uint256 rewardDebt;
    }

    uint256 public constant EPOCH_BLOCKS = 7200;
    uint256 private constant PREC = 1e12;

    IToken public immutable rewardToken;
    address public immutable admin;

    PoolInfo[] public pools;
    mapping(uint256 => mapping(address => Position)) public positions;

    event PoolAdded(uint256 indexed pid, address stakeToken, uint256 emissionPerEpoch);
    event Staked(uint256 indexed pid, address indexed user, uint256 amount);
    event Unstaked(uint256 indexed pid, address indexed user, uint256 amount);
    event Harvested(uint256 indexed pid, address indexed user, uint256 amount);

    constructor(IToken _rewardToken) {
        rewardToken = _rewardToken;
        admin = msg.sender;
    }

    function currentEpoch() public view returns (uint256) {
        return block.number / EPOCH_BLOCKS;
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function addPool(IToken stakeToken, uint256 emissionPerEpoch) external returns (uint256 pid) {
        require(msg.sender == admin, "admin only");
        pid = pools.length;
        pools.push(
            PoolInfo({
                stakeToken: stakeToken,
                emissionPerEpoch: emissionPerEpoch,
                lastEpoch: currentEpoch(),
                accPerShare: 0,
                totalStaked: 0
            })
        );
        emit PoolAdded(pid, address(stakeToken), emissionPerEpoch);
    }

    // Settlement: credit every epoch elapsed since the pool was last checkpointed.
    function _checkpoint(uint256 pid) internal {
        PoolInfo storage p = pools[pid];
        uint256 epoch = currentEpoch();
        if (epoch <= p.lastEpoch) {
            return;
        }
        uint256 epochsElapsed = epoch - p.lastEpoch;
        p.lastEpoch = epoch;
        if (p.totalStaked == 0) {
            return;
        }
        p.accPerShare += (epochsElapsed * p.emissionPerEpoch * PREC) / p.totalStaked;
    }

    function _send(address to, uint256 amount) private {
        require(rewardToken.transfer(to, amount), "reward transfer");
    }

    function stake(uint256 pid, uint256 amount) external {
        require(amount != 0, "zero");
        _checkpoint(pid);
        PoolInfo storage p = pools[pid];
        Position storage pos = positions[pid][msg.sender];
        uint256 owed = (pos.amount * p.accPerShare) / PREC - pos.rewardDebt;

        pos.amount += amount;
        p.totalStaked += amount;
        pos.rewardDebt = (pos.amount * p.accPerShare) / PREC;

        require(p.stakeToken.transferFrom(msg.sender, address(this), amount), "stake transfer");
        if (owed != 0) {
            _send(msg.sender, owed);
        }
        emit Staked(pid, msg.sender, amount);
    }

    function unstake(uint256 pid, uint256 amount) external {
        Position storage pos = positions[pid][msg.sender];
        require(amount != 0 && pos.amount >= amount, "bad amount");
        _checkpoint(pid);
        PoolInfo storage p = pools[pid];
        uint256 owed = (pos.amount * p.accPerShare) / PREC - pos.rewardDebt;

        pos.amount -= amount;
        p.totalStaked -= amount;
        pos.rewardDebt = (pos.amount * p.accPerShare) / PREC;

        require(p.stakeToken.transfer(msg.sender, amount), "stake return");
        if (owed != 0) {
            _send(msg.sender, owed);
        }
        emit Unstaked(pid, msg.sender, amount);
    }

    function harvest(uint256 pid) external {
        _checkpoint(pid);
        PoolInfo storage p = pools[pid];
        Position storage pos = positions[pid][msg.sender];
        uint256 owed = (pos.amount * p.accPerShare) / PREC - pos.rewardDebt;

        pos.rewardDebt = (pos.amount * p.accPerShare) / PREC;
        if (owed != 0) {
            _send(msg.sender, owed);
        }
        emit Harvested(pid, msg.sender, owed);
    }
}
