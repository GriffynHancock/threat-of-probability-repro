// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Weighted operator allocation. Unallocated rewards are split across operators by weight at each touch.
contract OperatorAllocationBook {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;

    struct Operator {
        address account;
        uint256 weightBps;
        uint256 totalStaked;
        uint256 rewardIndex;
        bool active;
    }

    IERC20 public immutable token;
    address public immutable admin;

    Operator[] public operators;
    uint256 public unallocatedRewards;

    mapping(uint256 => mapping(address => uint256)) public stakeOf;
    mapping(uint256 => mapping(address => uint256)) public indexPaid;
    mapping(uint256 => mapping(address => uint256)) public owed;

    event OperatorAdded(uint256 indexed id, address account, uint256 weightBps);
    event Allocated(address indexed user, uint256 indexed id, uint256 amount);
    event Released(address indexed user, uint256 indexed id, uint256 amount);
    event RewardsReported(uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed id, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        admin = msg.sender;
    }

    function addOperator(address account, uint256 weightBps) external {
        require(msg.sender == admin, "admin");
        require(weightBps <= BPS, "weight");
        operators.push(Operator(account, weightBps, 0, 0, true));
        emit OperatorAdded(operators.length - 1, account, weightBps);
    }

    function reportRewards(uint256 amount) external {
        require(msg.sender == admin, "admin");
        require(amount > 0, "zero");
        unallocatedRewards += amount;
        emit RewardsReported(amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function _rebalanceWeights() internal {
        uint256 pool = unallocatedRewards;
        if (pool == 0) return;
        uint256 distributed;
        uint256 n = operators.length;
        for (uint256 i = 0; i < n; i++) {
            Operator storage o = operators[i];
            if (!o.active || o.totalStaked == 0) continue;
            uint256 share = (pool * o.weightBps) / BPS;
            if (share == 0) continue;
            distributed += share;
            o.rewardIndex += (share * PRECISION) / o.totalStaked;
        }
        unallocatedRewards = pool - distributed;
    }

    function _settleOwed(uint256 id, address who) internal {
        uint256 idx = operators[id].rewardIndex;
        owed[id][who] += (stakeOf[id][who] * (idx - indexPaid[id][who])) / PRECISION;
        indexPaid[id][who] = idx;
    }

    function allocateToOperator(uint256 id, uint256 amount) external {
        require(amount > 0, "zero");
        require(id < operators.length && operators[id].active, "operator");
        _rebalanceWeights();
        _settleOwed(id, msg.sender);
        stakeOf[id][msg.sender] += amount;
        operators[id].totalStaked += amount;
        emit Allocated(msg.sender, id, amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function releaseAllocation(uint256 id, uint256 amount) external {
        _rebalanceWeights();
        _settleOwed(id, msg.sender);
        require(stakeOf[id][msg.sender] >= amount, "insufficient");
        stakeOf[id][msg.sender] -= amount;
        operators[id].totalStaked -= amount;
        emit Released(msg.sender, id, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }

    function claimAllocated(uint256 id) external returns (uint256 amount) {
        _rebalanceWeights();
        _settleOwed(id, msg.sender);
        amount = owed[id][msg.sender];
        require(amount > 0, "none");
        owed[id][msg.sender] = 0;
        emit RewardsClaimed(msg.sender, id, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }
}
