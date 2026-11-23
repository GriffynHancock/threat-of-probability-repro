// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IERC20Core {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWeightRegistry {
    function weightOf(address holder) external view returns (uint256);
    function totalWeight() external view returns (uint256);
}

/// @title EpochBudgetDistributor
/// @notice Rewards are funded per epoch by an operator (manual notification).
/// Each epoch stores its amount and the cumulative per-weight index after it.
/// Holders are caught up across the epochs they have not yet seen.
/// Weight changes must go through the registry, which calls `registryTouched` before it changes a holder.
/// That hook is what makes each epoch be credited at the weight the holder actually had.
contract EpochBudgetDistributor {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_CATCHUP = 64;

    error OperatorOnly();
    error ZeroAmount();
    error NothingPending();
    error PaymentFailed();
    error NotRegistry();

    struct Epoch {
        uint256 amount;
        uint256 indexAfter;
        uint64 notifiedAt;
    }

    event EpochNotified(uint256 indexed epochId, uint256 amount, uint256 indexAfter);
    event HolderCaughtUp(address indexed holder, uint256 epochsProcessed, uint256 owed);
    event HolderPaid(address indexed holder, uint256 amount);
    event OperatorChanged(address indexed previous, address indexed current);

    IERC20Core public immutable payoutToken;
    IWeightRegistry public immutable registry;
    address public operator;

    Epoch[] public epochs;
    uint256 public cumulativeIndex;

    mapping(address => uint256) public seenEpochs;
    mapping(address => uint256) public indexSnapshot;
    mapping(address => uint256) public owedTo;

    constructor(IERC20Core payoutToken_, IWeightRegistry registry_) {
        payoutToken = payoutToken_;
        registry = registry_;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OperatorOnly();
        _;
    }

    function setOperator(address next) external onlyOperator {
        emit OperatorChanged(operator, next);
        operator = next;
    }

    /// @notice Funds the next epoch. Caller must approve this contract first.
    function notifyEpoch(uint256 amount) external onlyOperator returns (uint256 epochId) {
        if (amount == 0) revert ZeroAmount();
        uint256 supply = registry.totalWeight();
        require(supply > 0, "no weight");
        if (!payoutToken.transferFrom(msg.sender, address(this), amount)) revert PaymentFailed();

        cumulativeIndex = cumulativeIndex + (amount * WAD) / supply;
        epochId = epochs.length;
        epochs.push(Epoch({
            amount: amount,
            indexAfter: cumulativeIndex,
            notifiedAt: uint64(block.timestamp)
        }));
        emit EpochNotified(epochId, amount, cumulativeIndex);
    }

    /// @notice Called by the registry when a holder's weight is about to change.
    function registryTouched(address holder) external {
        if (msg.sender != address(registry)) revert NotRegistry();
        _catchUpEpochs(holder);
    }

    /// @notice Claims everything owed to the caller.
    function collect() external returns (uint256 amount) {
        _catchUpEpochs(msg.sender);
        amount = owedTo[msg.sender];
        if (amount == 0) revert NothingPending();
        owedTo[msg.sender] = 0;
        if (!payoutToken.transfer(msg.sender, amount)) revert PaymentFailed();
        emit HolderPaid(msg.sender, amount);
    }

    function owedNow(address holder) external view returns (uint256) {
        uint256 w = registry.weightOf(holder);
        uint256 seen = seenEpochs[holder];
        if (w == 0 || seen >= epochs.length) return owedTo[holder];
        uint256 index = cumulativeIndex;
        return owedTo[holder] + (w * (index - indexSnapshot[holder])) / WAD;
    }

    /// Settlement helper. Walks forward from the holder's last-seen epoch, bounded per call.
    /// The index delta is the same whether it is taken in one step or many, so the bound only
    /// limits gas; it does not change the amount owed.
    function _catchUpEpochs(address holder) internal {
        uint256 total = epochs.length;
        uint256 seen = seenEpochs[holder];
        if (seen >= total) return;

        uint256 w = registry.weightOf(holder);
        uint256 stop = total - seen > MAX_CATCHUP ? seen + MAX_CATCHUP : total;

        uint256 index = epochs[stop - 1].indexAfter;
        if (w > 0) {
            owedTo[holder] = owedTo[holder] + (w * (index - indexSnapshot[holder])) / WAD;
        }
        indexSnapshot[holder] = index;
        seenEpochs[holder] = stop;
        emit HolderCaughtUp(holder, stop - seen, owedTo[holder]);
    }
}
