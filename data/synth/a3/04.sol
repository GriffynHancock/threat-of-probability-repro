// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract ClockLazyEpochPool {
    uint256 public constant PRECISION = 1e18;

    IERC20 public immutable token;
    IERC20 public immutable rewardToken;
    uint256 public immutable epochSeconds;
    uint256 public immutable rewardPerEpoch;
    uint256 public immutable t0;

    struct Snapshot {
        uint256 totalAtClose;
        uint256 rewardPerShare;
    }

    // Closed epochs, keyed by index. Epoch k covers [t0 + k*epochSeconds, t0 + (k+1)*epochSeconds).
    mapping(uint256 => Snapshot) public snapshots;
    uint256 public snapshotCount;

    uint256 public totalBalance;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public cursor; // next snapshot index not yet credited
    mapping(address => uint256) public owed;

    event Staked(address indexed who, uint256 amount);
    event Unstaked(address indexed who, uint256 amount);
    event Collected(address indexed who, uint256 amount);
    event SnapshotTaken(uint256 indexed index, uint256 totalAtClose);

    constructor(IERC20 _token, IERC20 _rewardToken, uint256 _epochSeconds, uint256 _rewardPerEpoch) {
        require(_epochSeconds > 0, "epochSeconds");
        token = _token;
        rewardToken = _rewardToken;
        epochSeconds = _epochSeconds;
        rewardPerEpoch = _rewardPerEpoch;
        t0 = block.timestamp;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "amount");
        _catchUp();
        _creditUser(msg.sender);
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        balances[msg.sender] += amount;
        totalBalance += amount;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(amount > 0, "amount");
        _catchUp();
        _creditUser(msg.sender);
        require(balances[msg.sender] >= amount, "insufficient");
        balances[msg.sender] -= amount;
        totalBalance -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
        emit Unstaked(msg.sender, amount);
    }

    function collect() external {
        _catchUp();
        _creditUser(msg.sender);
        uint256 amount = owed[msg.sender];
        require(amount > 0, "nothing");
        owed[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amount), "transfer");
        emit Collected(msg.sender, amount);
    }

    /// @dev Records a snapshot for every epoch that has elapsed since the last one.
    ///      The reward for an epoch is only emitted if somebody was staked when it closed.
    function _catchUp() internal {
        uint256 target = (block.timestamp - t0) / epochSeconds;
        while (snapshotCount < target) {
            uint256 total = totalBalance;
            uint256 perShare = total == 0 ? 0 : rewardPerEpoch * PRECISION / total;
            snapshots[snapshotCount] = Snapshot(total, perShare);
            emit SnapshotTaken(snapshotCount, total);
            snapshotCount += 1;
        }
    }

    /// @dev Adds the user's share of each snapshot they have not yet been credited for.
    function _creditUser(address who) internal {
        uint256 bal = balances[who];
        uint256 end = snapshotCount;
        for (uint256 k = cursor[who]; k < end; ++k) {
            owed[who] += bal * snapshots[k].rewardPerShare / PRECISION;
        }
        cursor[who] = end;
    }
}
