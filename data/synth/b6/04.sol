// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Bridge-side escrow. Locked tokens accrue yield pro-rata from a funded reserve.
contract BridgeEscrowYield {
    uint256 private constant PRECISION = 1e18;

    struct Lock {
        uint256 amount;
        uint256 rewardDebt;
        uint256 accrued;
        uint64 destChain;
    }

    IERC20 public immutable token;
    address public immutable operator;
    uint256 public immutable emissionPerSecond;

    uint256 public totalLocked;
    uint256 public accRewardPerToken;
    uint256 public lastAccrual;
    uint256 public rewardReserve;
    uint256 public nonce;

    mapping(address => Lock) public locks;

    event Locked(address indexed user, uint64 indexed destChain, uint256 amount, uint256 nonce);
    event Unlocked(address indexed user, uint256 amount);
    event YieldClaimed(address indexed user, uint256 amount);
    event RewardsFunded(uint256 amount);

    constructor(IERC20 _token, uint256 _emissionPerSecond) {
        token = _token;
        operator = msg.sender;
        emissionPerSecond = _emissionPerSecond;
        lastAccrual = block.timestamp;
    }

    function fundRewards(uint256 amount) external {
        require(msg.sender == operator, "not operator");
        rewardReserve += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        emit RewardsFunded(amount);
    }

    function _accrueLockYield() internal {
        uint256 dt = block.timestamp - lastAccrual;
        lastAccrual = block.timestamp;
        if (dt == 0 || totalLocked == 0) return;
        uint256 emission = dt * emissionPerSecond;
        if (emission > rewardReserve) emission = rewardReserve;
        rewardReserve -= emission;
        accRewardPerToken += (emission * PRECISION) / totalLocked;
    }

    function _pendingYield(Lock storage l) internal view returns (uint256) {
        return (l.amount * accRewardPerToken) / PRECISION - l.rewardDebt;
    }

    function lockForBridge(uint256 amount, uint64 destChain) external returns (uint256 id) {
        require(amount > 0, "zero");
        _accrueLockYield();
        Lock storage l = locks[msg.sender];
        l.accrued += _pendingYield(l);
        l.amount += amount;
        l.rewardDebt = (l.amount * accRewardPerToken) / PRECISION;
        l.destChain = destChain;
        totalLocked += amount;
        id = ++nonce;
        emit Locked(msg.sender, destChain, amount, id);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function unlockFromBridge(uint256 amount) external {
        _accrueLockYield();
        Lock storage l = locks[msg.sender];
        require(l.amount >= amount, "insufficient");
        l.accrued += _pendingYield(l);
        l.amount -= amount;
        l.rewardDebt = (l.amount * accRewardPerToken) / PRECISION;
        totalLocked -= amount;
        emit Unlocked(msg.sender, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }

    function claimBridgeYield() external returns (uint256 owed) {
        _accrueLockYield();
        Lock storage l = locks[msg.sender];
        l.accrued += _pendingYield(l);
        l.rewardDebt = (l.amount * accRewardPerToken) / PRECISION;
        owed = l.accrued;
        require(owed > 0, "nothing");
        l.accrued = 0;
        emit YieldClaimed(msg.sender, owed);
        require(token.transfer(msg.sender, owed), "xfer");
    }
}
