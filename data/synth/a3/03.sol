// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title OperatorEpochPool
 * @notice Epochs are opened and closed by an operator via closeEpoch(). Closing an
 *         epoch snapshots the total stake and the reward it emits into the history.
 *         A user's entitlement is computed when they next touch the pool, by walking
 *         every epoch closed since their last settlement.
 */
contract OperatorEpochPool {
    // Fixed-point scale for reward-per-share values.
    uint256 private constant PRECISION = 1e18;

    struct EpochRecord {
        uint256 totalAtClose;
        uint256 rewardEmitted;
        uint256 rewardPerShare; // scaled by PRECISION
    }

    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    address public immutable operator;
    uint256 public immutable rewardPerEpoch;

    EpochRecord[] public history;
    uint256 public totalStaked;

    mapping(address => uint256) public staked;
    // Index of the first epoch whose reward has not yet been credited to the account.
    mapping(address => uint256) public settledThrough;
    mapping(address => uint256) public accrued;

    event Deposit(address indexed account, uint256 amount, uint256 openEpoch);
    event Withdraw(address indexed account, uint256 amount, uint256 openEpoch);
    event Claim(address indexed account, uint256 amount);
    event EpochClosed(uint256 indexed epoch, uint256 totalAtClose, uint256 rewardEmitted);

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    constructor(IERC20 _stakeToken, IERC20 _rewardToken, uint256 _rewardPerEpoch) {
        require(address(_stakeToken) != address(0), "stake token");
        require(address(_rewardToken) != address(0), "reward token");
        stakeToken = _stakeToken;
        rewardToken = _rewardToken;
        operator = msg.sender;
        rewardPerEpoch = _rewardPerEpoch;
    }

    /// @notice Index of the epoch currently accumulating stake.
    function openEpochIndex() public view returns (uint256) {
        return history.length;
    }

    /// @notice Snapshot the open epoch. Its reward is split pro rata by the stake at this moment.
    function closeEpoch() external onlyOperator {
        uint256 total = totalStaked;
        uint256 emitted = total > 0 ? rewardPerEpoch : 0;
        uint256 perShare = total > 0 ? rewardPerEpoch * PRECISION / total : 0;
        history.push(EpochRecord(total, emitted, perShare));
        emit EpochClosed(history.length - 1, total, emitted);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        // Credit every epoch closed so far at the balance the user held during it,
        // before the balance changes.
        _settle(msg.sender);
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "transferFrom");
        staked[msg.sender] += amount;
        totalStaked += amount;
        emit Deposit(msg.sender, amount, history.length);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "zero amount");
        require(staked[msg.sender] >= amount, "insufficient stake");
        _settle(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        require(stakeToken.transfer(msg.sender, amount), "transfer");
        emit Withdraw(msg.sender, amount, history.length);
    }

    function claim() external {
        _settle(msg.sender);
        uint256 amount = accrued[msg.sender];
        require(amount > 0, "nothing to claim");
        accrued[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amount), "transfer");
        emit Claim(msg.sender, amount);
    }

    /// @dev Walks the epochs closed since the last settlement. The account's balance is
    ///      constant over that range because every balance change settles first.
    function _settle(address account) internal {
        uint256 start = settledThrough[account];
        uint256 end = history.length;
        uint256 bal = staked[account];
        uint256 gain;
        for (uint256 i = start; i < end; i++) {
            gain += bal * history[i].rewardPerShare / PRECISION;
        }
        accrued[account] += gain;
        settledThrough[account] = end;
    }
}
