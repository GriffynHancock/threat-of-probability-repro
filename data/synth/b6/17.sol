// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Prepaid compute credits funded by token deposits. Unused credits expire after a TTL.
contract YieldCreditMeter {
    uint256 public constant CREDITS_PER_TOKEN = 1000;
    uint256 public constant TTL = 30 days;
    uint256 public constant REFUND_DELAY = 2 days;

    struct Meter {
        uint256 credits;
        uint256 expiresAt;
        uint256 burned;
    }

    IERC20 public immutable token;
    address public immutable treasury;
    uint256 public totalCredits;
    uint256 public expiredCredits;
    uint256 public totalBurned;

    mapping(address => Meter) public meters;
    mapping(address => uint256) public refundOwed;
    mapping(address => uint256) public refundReadyAt;

    error ZeroAmount();
    error InsufficientCredits(uint256 have, uint256 want);
    error NotTreasury();

    event CreditsBought(address indexed user, uint256 tokens, uint256 credits);
    event CreditsSpent(address indexed user, uint256 credits);
    event CreditsExpired(address indexed user, uint256 credits);
    event RefundRequested(address indexed user, uint256 tokens, uint256 readyAt);
    event RefundClaimed(address indexed user, uint256 tokens);

    constructor(IERC20 _token, address _treasury) {
        token = _token;
        treasury = _treasury;
    }

    function _expireStale(address who) internal {
        Meter storage m = meters[who];
        if (m.credits == 0 || block.timestamp < m.expiresAt) return;
        uint256 lost = m.credits;
        m.credits = 0;
        totalCredits -= lost;
        expiredCredits += lost;
        emit CreditsExpired(who, lost);
    }

    function buyCredits(uint256 tokens) external returns (uint256 minted) {
        if (tokens == 0) revert ZeroAmount();
        _expireStale(msg.sender);
        Meter storage m = meters[msg.sender];
        minted = tokens * CREDITS_PER_TOKEN;
        m.credits += minted;
        m.expiresAt = block.timestamp + TTL;
        totalCredits += minted;
        emit CreditsBought(msg.sender, tokens, minted);
        require(token.transferFrom(msg.sender, address(this), tokens), "pull");
    }

    function spendCredits(uint256 credits) external {
        if (credits == 0) revert ZeroAmount();
        _expireStale(msg.sender);
        Meter storage m = meters[msg.sender];
        if (m.credits < credits) revert InsufficientCredits(m.credits, credits);
        m.credits -= credits;
        m.burned += credits;
        totalCredits -= credits;
        totalBurned += credits;
        emit CreditsSpent(msg.sender, credits);
    }

    function refundUnused(uint256 credits) external {
        if (credits == 0) revert ZeroAmount();
        _expireStale(msg.sender);
        Meter storage m = meters[msg.sender];
        if (m.credits < credits) revert InsufficientCredits(m.credits, credits);
        m.credits -= credits;
        totalCredits -= credits;
        uint256 tokens = credits / CREDITS_PER_TOKEN;
        refundOwed[msg.sender] += tokens;
        refundReadyAt[msg.sender] = block.timestamp + REFUND_DELAY;
        emit RefundRequested(msg.sender, tokens, refundReadyAt[msg.sender]);
    }

    function claimRefund() external returns (uint256 tokens) {
        tokens = refundOwed[msg.sender];
        require(tokens > 0, "none");
        require(block.timestamp >= refundReadyAt[msg.sender], "locked");
        refundOwed[msg.sender] = 0;
        emit RefundClaimed(msg.sender, tokens);
        require(token.transfer(msg.sender, tokens), "xfer");
    }

    function sweepToTreasury() external {
        if (msg.sender != treasury) revert NotTreasury();
        uint256 pool = expiredCredits + totalBurned;
        uint256 tokens = pool / CREDITS_PER_TOKEN;
        expiredCredits = pool % CREDITS_PER_TOKEN;
        totalBurned = 0;
        require(token.transfer(treasury, tokens), "xfer");
    }
}
