// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Gauge weight voting with a per-account weight budget. Each account
/// has a fixed budget (scaled by its vote-escrow balance); the sum of its
/// allocations to gauges may not exceed that budget.
contract GaugeWeightVoting {
    IERC20 public immutable escrow;
    address public immutable admin;

    mapping(address => uint256) public escrowBalance;
    mapping(address => uint256) public allocatedBy;
    mapping(address => mapping(uint256 => uint256)) public votes;
    mapping(uint256 => uint256) public gaugeWeight;
    uint256 public totalWeight;

    event BudgetSet(address indexed account, uint256 budget);
    event VoteCast(address indexed account, uint256 indexed gaugeId, uint256 weight);
    event VoteRemoved(address indexed account, uint256 indexed gaugeId, uint256 weight);

    constructor(IERC20 _escrow) {
        escrow = _escrow;
        admin = msg.sender;
    }

    function setEscrowBalance(address account, uint256 balance) external {
        require(msg.sender == admin, "not admin");
        escrowBalance[account] = balance;
        emit BudgetSet(account, balance);
    }

    /// @notice Casts or increases a vote on a gauge within the caller's budget.
    function castVote(uint256 gaugeId, uint256 weight) external {
        require(weight > 0, "zero weight");
        _refreshAccount(msg.sender);
        require(allocatedBy[msg.sender] + weight <= escrowBalance[msg.sender], "over budget");
        votes[msg.sender][gaugeId] += weight;
        allocatedBy[msg.sender] += weight;
        gaugeWeight[gaugeId] += weight;
        totalWeight += weight;
        emit VoteCast(msg.sender, gaugeId, weight);
    }

    /// @notice Withdraws part of an existing vote.
    function removeVote(uint256 gaugeId, uint256 weight) external {
        require(weight <= votes[msg.sender][gaugeId], "not enough votes");
        _refreshAccount(msg.sender);
        votes[msg.sender][gaugeId] -= weight;
        allocatedBy[msg.sender] -= weight;
        gaugeWeight[gaugeId] -= weight;
        totalWeight -= weight;
        emit VoteRemoved(msg.sender, gaugeId, weight);
    }

    /// @notice Weight the account can still allocate.
    function remainingBudget(address account) external view returns (uint256) {
        uint256 budget = escrowBalance[account];
        uint256 used = allocatedBy[account];
        return used >= budget ? 0 : budget - used;
    }

    /// @dev Reconciles the account's allocations against its current budget.
    /// If the budget shrank below what is allocated, the excess is not clawed
    /// back here; the account just cannot add more until it is back within budget.
    function _refreshAccount(address account) internal {
        uint256 budget = escrowBalance[account];
        if (allocatedBy[account] > budget) {
            emit BudgetSet(account, budget);
        }
    }
}
