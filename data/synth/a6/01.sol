// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Read-only view of balances held by a separate staking ledger.
interface IStakeLedger {
    function balanceOf(address account) external view returns (uint256);
    function totalSupplied() external view returns (uint256);
}

/// @title EmissionRewardPool
/// @notice Streams a constant per-second emission to holders of balances kept in an external ledger.
/// Accrual is index-based: a global index grows with time, and each account settles lazily against it.
/// The ledger calls `onBalanceChange` before it modifies a balance so the account is brought current first.
contract EmissionRewardPool {
    uint256 private constant PRECISION = 1e18;

    error NotOwner();
    error ZeroAddress();
    error NothingToClaim();
    error TransferFailed();
    error NotLedger();

    event RateChanged(uint256 previousRate, uint256 newRate);
    event IndexAdvanced(uint256 newIndex, uint256 emitted);
    event AccountSettled(address indexed account, uint256 accruedTotal);
    event Claimed(address indexed account, uint256 amount);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);

    IERC20 public immutable rewardToken;
    IStakeLedger public immutable ledger;
    address public owner;

    uint256 public emissionPerSecond;
    uint256 public lastAdvanceTime;
    uint256 public rewardIndex;

    mapping(address => uint256) public accountIndex;
    mapping(address => uint256) public accrued;
    mapping(address => bool) private _tracked;

    constructor(IERC20 rewardToken_, IStakeLedger ledger_, uint256 emissionPerSecond_) {
        if (address(rewardToken_) == address(0) || address(ledger_) == address(0)) revert ZeroAddress();
        rewardToken = rewardToken_;
        ledger = ledger_;
        owner = msg.sender;
        emissionPerSecond = emissionPerSecond_;
        lastAdvanceTime = block.timestamp;
        emit RateChanged(0, emissionPerSecond_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setEmissionRate(uint256 newRate) external onlyOwner {
        _advanceIndex();
        emit RateChanged(emissionPerSecond, newRate);
        emissionPerSecond = newRate;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Called by the ledger immediately before it changes `account`'s balance.
    function onBalanceChange(address account) external {
        if (msg.sender != address(ledger)) revert NotLedger();
        _settleAccount(account);
    }

    /// @notice Brings the caller current and pays out everything accrued so far.
    function claim() external returns (uint256 amount) {
        _settleAccount(msg.sender);
        amount = accrued[msg.sender];
        if (amount == 0) revert NothingToClaim();
        accrued[msg.sender] = 0;
        if (!rewardToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Claimed(msg.sender, amount);
    }

    /// @notice Pending reward for `account`, computed without writing state.
    function pendingReward(address account) external view returns (uint256) {
        if (!_tracked[account]) return accrued[account];
        uint256 index = _projectedIndex();
        uint256 bal = ledger.balanceOf(account);
        return accrued[account] + (bal * (index - accountIndex[account])) / PRECISION;
    }

    function _projectedIndex() internal view returns (uint256) {
        uint256 supply = ledger.totalSupplied();
        uint256 elapsed = block.timestamp - lastAdvanceTime;
        if (elapsed == 0 || supply == 0 || emissionPerSecond == 0) return rewardIndex;
        return rewardIndex + (elapsed * emissionPerSecond * PRECISION) / supply;
    }

    function _advanceIndex() internal {
        uint256 projected = _projectedIndex();
        uint256 elapsed = block.timestamp - lastAdvanceTime;
        if (projected != rewardIndex) {
            emit IndexAdvanced(projected, elapsed * emissionPerSecond);
        }
        rewardIndex = projected;
        lastAdvanceTime = block.timestamp;
    }

    /// @dev Accrual starts at an account's first checkpoint; time before that is not credited to it.
    function _settleAccount(address account) internal {
        _advanceIndex();
        if (!_tracked[account]) {
            _tracked[account] = true;
            accountIndex[account] = rewardIndex;
            return;
        }
        uint256 bal = ledger.balanceOf(account);
        uint256 delta = rewardIndex - accountIndex[account];
        accountIndex[account] = rewardIndex;
        if (bal > 0 && delta > 0) {
            accrued[account] = accrued[account] + (bal * delta) / PRECISION;
        }
        emit AccountSettled(account, accrued[account]);
    }
}
