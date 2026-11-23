// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title GovernedEpochLedger
/// @notice Rewards are pre-funded per epoch by a governor and distributed when the
///         governor closes the epoch. Reward funded while nothing is staked is carried
///         into the next closed epoch rather than lost.
contract GovernedEpochLedger {
    uint256 private constant SCALE = 1e18;

    /// @dev One entry per closed epoch. `rateAfter` is the cumulative reward per staked unit.
    struct Ledger {
        uint256 stakeAtClose;
        uint256 distributed;
        uint256 rateAfter;
    }

    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    address public immutable governor;

    Ledger[] public ledger;
    uint256 public rateAcc;
    uint256 public stakeTotal;
    uint256 public nextEpochFunding;
    uint256 public carry;

    mapping(address => uint256) public principal;
    mapping(address => uint256) public checkpoint;
    mapping(address => uint256) public rewards;

    event Pledged(address indexed who, uint256 amount);
    event Released(address indexed who, uint256 amount);
    event Paid(address indexed who, uint256 amount);
    event FundingAdded(uint256 amount);
    event EpochClosed(uint256 indexed index, uint256 distributed, uint256 carried);

    error NotGovernor();
    error InvalidAmount();
    error Insufficient();
    error PayoutFailed();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(IERC20 _stake, IERC20 _reward) {
        stakeToken = _stake;
        rewardToken = _reward;
        governor = msg.sender;
    }

    function pledge(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _bank(msg.sender);
        if (!stakeToken.transferFrom(msg.sender, address(this), amount)) revert PayoutFailed();
        principal[msg.sender] += amount;
        stakeTotal += amount;
        emit Pledged(msg.sender, amount);
    }

    function release(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _bank(msg.sender);
        if (principal[msg.sender] < amount) revert Insufficient();
        principal[msg.sender] -= amount;
        stakeTotal -= amount;
        if (!stakeToken.transfer(msg.sender, amount)) revert PayoutFailed();
        emit Released(msg.sender, amount);
    }

    function harvest() external {
        _bank(msg.sender);
        uint256 amount = rewards[msg.sender];
        if (amount == 0) revert InvalidAmount();
        rewards[msg.sender] = 0;
        if (!rewardToken.transfer(msg.sender, amount)) revert PayoutFailed();
        emit Paid(msg.sender, amount);
    }

    /// @notice Adds reward tokens to the pot for the next epoch to close.
    function fundNextEpoch(uint256 amount) external onlyGovernor {
        if (amount == 0) revert InvalidAmount();
        if (!rewardToken.transferFrom(msg.sender, address(this), amount)) revert PayoutFailed();
        nextEpochFunding += amount;
        emit FundingAdded(amount);
    }

    /// @notice Closes the current epoch, distributing the pot (plus any carry) pro rata.
    function closeEpoch() external onlyGovernor {
        uint256 pot = nextEpochFunding + carry;
        nextEpochFunding = 0;
        uint256 total = stakeTotal;
        if (total == 0) {
            carry = pot;
            ledger.push(Ledger(0, 0, rateAcc));
            emit EpochClosed(ledger.length - 1, 0, pot);
            return;
        }
        carry = 0;
        rateAcc += pot * SCALE / total;
        ledger.push(Ledger(total, pot, rateAcc));
        emit EpochClosed(ledger.length - 1, pot, 0);
    }

    function epochCount() external view returns (uint256) {
        return ledger.length;
    }

    /// @dev Books the reward accrued since the account's checkpoint. Must run before any
    ///      change to `principal`, so the old balance is credited for the old rate.
    function _bank(address who) internal {
        uint256 delta = rateAcc - checkpoint[who];
        if (delta > 0) {
            rewards[who] += principal[who] * delta / SCALE;
        }
        checkpoint[who] = rateAcc;
    }
}
