// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title GovernanceVoteEscrowV2
/// @notice Flat-weight vote escrow with a fixed lock. Fees accrue per unit of voting power and are
///         settled by _updateVotingPower before any change to a lock.
contract GovernanceVoteEscrowV2 {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant LOCK_LENGTH = 365 days;

    struct Lock {
        uint256 amount;
        uint256 power;
        uint256 end;
        uint256 feeDebt;
        uint256 feesOwed;
    }

    IERC20 public immutable govToken;
    IERC20 public immutable feeToken;
    uint256 public totalPower;
    uint256 public feePerPower;

    mapping(address => Lock) public locks;

    event LockCreated(address indexed who, uint256 amount, uint256 end);
    event LockWithdrawn(address indexed who, uint256 amount);
    event FeesDeposited(uint256 amount);
    event FeesClaimed(address indexed who, uint256 amount);

    constructor(IERC20 _gov, IERC20 _fee) {
        govToken = _gov;
        feeToken = _fee;
    }

    function depositFees(uint256 amount) external {
        require(totalPower > 0, "no power");
        require(feeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        feePerPower += (amount * PRECISION) / totalPower;
        emit FeesDeposited(amount);
    }

    function _updateVotingPower(address who) internal {
        Lock storage l = locks[who];
        l.feesOwed += (l.power * (feePerPower - l.feeDebt)) / PRECISION;
        l.feeDebt = feePerPower;
        uint256 newPower = l.amount;
        totalPower = totalPower - l.power + newPower;
        l.power = newPower;
    }

    /// @notice Create or extend a lock. Each call restarts the lock end.
    function createLock(uint256 amount) external {
        require(amount > 0, "zero amount");
        _updateVotingPower(msg.sender);
        Lock storage l = locks[msg.sender];
        l.amount += amount;
        l.end = block.timestamp + LOCK_LENGTH;
        _syncPowerAfterDeposit(msg.sender);
        require(govToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit LockCreated(msg.sender, amount, l.end);
    }

    function _syncPowerAfterDeposit(address who) internal {
        Lock storage l = locks[who];
        totalPower = totalPower - l.power + l.amount;
        l.power = l.amount;
    }

    /// @notice Withdraw the locked balance after `end`.
    function withdrawLocked() external {
        _updateVotingPower(msg.sender);
        Lock storage l = locks[msg.sender];
        require(block.timestamp >= l.end, "still locked");
        uint256 amount = l.amount;
        require(amount > 0, "nothing locked");
        l.amount -= amount;
        totalPower -= l.power;
        l.power = 0;
        require(govToken.transfer(msg.sender, amount), "transfer failed");
        emit LockWithdrawn(msg.sender, amount);
    }

    /// @notice Claim fees accrued on voting power.
    function claimFees() external {
        _updateVotingPower(msg.sender);
        Lock storage l = locks[msg.sender];
        uint256 amount = l.feesOwed;
        require(amount > 0, "nothing to claim");
        l.feesOwed = 0;
        require(feeToken.transfer(msg.sender, amount), "transfer failed");
        emit FeesClaimed(msg.sender, amount);
    }
}
