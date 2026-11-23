// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Minimal {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

error ZeroAmount();
error InsufficientShares(uint256 requested, uint256 available);
error TransferFailed();
error NothingToClaim();
error Unauthorized();

contract TimeAccrualVault {
    uint256 internal constant PRECISION = 1e18;

    IERC20Minimal public immutable stakeAsset;
    IERC20Minimal public immutable rewardAsset;
    address public immutable governance;

    uint256 public ratePerSecond;
    uint256 public lastAccruedAt;
    uint256 public rewardIndex;
    uint256 public totalShares;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public owed;
    mapping(address => uint256) internal debtOf;

    event Entered(address indexed account, uint256 amount);
    event Exited(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event RateSet(uint256 ratePerSecond);

    constructor(IERC20Minimal stakeAsset_, IERC20Minimal rewardAsset_, uint256 ratePerSecond_) {
        stakeAsset = stakeAsset_;
        rewardAsset = rewardAsset_;
        governance = msg.sender;
        ratePerSecond = ratePerSecond_;
        lastAccruedAt = block.timestamp;
    }

    // Advance the global reward index to the current timestamp.
    function _advance() internal {
        if (block.timestamp > lastAccruedAt && totalShares != 0) {
            rewardIndex += ((block.timestamp - lastAccruedAt) * ratePerSecond * PRECISION) / totalShares;
        }
        lastAccruedAt = block.timestamp;
    }

    // Settle an account's pending rewards into its owed balance.
    function _accrue(address account) internal {
        _advance();
        owed[account] += (shares[account] * rewardIndex) / PRECISION - debtOf[account];
    }

    function _resetDebt(address account) internal {
        debtOf[account] = (shares[account] * rewardIndex) / PRECISION;
    }

    function pendingOf(address account) external view returns (uint256) {
        uint256 index = rewardIndex;
        if (block.timestamp > lastAccruedAt && totalShares != 0) {
            index += ((block.timestamp - lastAccruedAt) * ratePerSecond * PRECISION) / totalShares;
        }
        return owed[account] + (shares[account] * index) / PRECISION - debtOf[account];
    }

    function enter(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        shares[msg.sender] += amount;
        totalShares += amount;
        _resetDebt(msg.sender);
        if (!stakeAsset.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Entered(msg.sender, amount);
    }

    function exit(uint256 amount) external {
        uint256 held = shares[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > held) revert InsufficientShares(amount, held);
        _accrue(msg.sender);
        shares[msg.sender] = held - amount;
        totalShares -= amount;
        _resetDebt(msg.sender);
        if (!stakeAsset.transfer(msg.sender, amount)) revert TransferFailed();
        emit Exited(msg.sender, amount);
    }

    function claim() external {
        _accrue(msg.sender);
        _resetDebt(msg.sender);
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        owed[msg.sender] = 0;
        if (!rewardAsset.transfer(msg.sender, amount)) revert TransferFailed();
        emit Claimed(msg.sender, amount);
    }

    function setRate(uint256 newRate) external {
        if (msg.sender != governance) revert Unauthorized();
        _advance();
        ratePerSecond = newRate;
        emit RateSet(newRate);
    }
}
