// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Per-destination-chain escrow. Yield accrues per user from a guardian-funded reserve.
contract BridgeEscrowPerChain {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable token;
    address public immutable guardian;
    uint256 public yieldPerSecond;
    uint256 public yieldReserve;
    uint256 public totalEscrowed;
    uint256 public outboundNonce;

    mapping(address => uint256) public escrowOf;
    mapping(address => mapping(uint64 => uint256)) public lockedTo;
    mapping(address => uint256) public yieldOwed;
    mapping(address => uint256) public yieldCheckpoint;

    event EscrowOpened(address indexed user, uint64 indexed dstChain, uint256 amount, uint256 nonce);
    event EscrowReleased(address indexed user, uint64 indexed srcChain, uint256 amount);
    event YieldAccrued(address indexed user, uint256 amount);
    event YieldClaimed(address indexed user, uint256 amount);
    event YieldFunded(uint256 amount);

    constructor(IERC20 _token, uint256 _yieldPerSecond) {
        token = _token;
        guardian = msg.sender;
        yieldPerSecond = _yieldPerSecond;
    }

    function fundYield(uint256 amount) external {
        require(msg.sender == guardian, "not guardian");
        yieldReserve += amount;
        emit YieldFunded(amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function _settleEscrowYield(address who) internal {
        uint256 last = yieldCheckpoint[who];
        yieldCheckpoint[who] = block.timestamp;
        if (last == 0 || escrowOf[who] == 0) return;
        uint256 dt = block.timestamp - last;
        uint256 owedNow = (escrowOf[who] * dt * yieldPerSecond) / PRECISION;
        if (owedNow > yieldReserve) owedNow = yieldReserve;
        if (owedNow == 0) return;
        yieldReserve -= owedNow;
        yieldOwed[who] += owedNow;
        emit YieldAccrued(who, owedNow);
    }

    function escrowForBridge(uint64 dstChain, uint256 amount) external returns (uint256 nonce) {
        require(amount > 0, "zero");
        _settleEscrowYield(msg.sender);
        escrowOf[msg.sender] += amount;
        lockedTo[msg.sender][dstChain] += amount;
        totalEscrowed += amount;
        nonce = ++outboundNonce;
        emit EscrowOpened(msg.sender, dstChain, amount, nonce);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function releaseFromChain(uint64 srcChain, uint256 amount) external {
        _settleEscrowYield(msg.sender);
        require(lockedTo[msg.sender][srcChain] >= amount, "not locked to chain");
        lockedTo[msg.sender][srcChain] -= amount;
        escrowOf[msg.sender] -= amount;
        totalEscrowed -= amount;
        emit EscrowReleased(msg.sender, srcChain, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }

    function claimEscrowYield() external returns (uint256 out) {
        _settleEscrowYield(msg.sender);
        out = yieldOwed[msg.sender];
        require(out > 0, "nothing");
        yieldOwed[msg.sender] = 0;
        emit YieldClaimed(msg.sender, out);
        require(token.transfer(msg.sender, out), "xfer");
    }
}
