// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Daily check-ins build XP with a streak multiplier. XP can be withdrawn as a reward token.
contract StreakXP {
    error AlreadyCheckedIn(uint64 day);
    error InsufficientXP(uint256 have, uint256 want);
    error ZeroAmount();
    error TransferFailed();

    uint256 private constant PRECISION = 1e18;
    uint256 public constant DAY = 1 days;
    uint256 public constant BASE_XP = 10 * PRECISION;
    uint256 public constant MAX_MULTIPLIER = 5 * PRECISION;
    uint256 public constant STREAK_BONUS_TOKENS = 100 * PRECISION;
    uint32 public constant STREAK_FOR_BONUS = 7;

    IERC20 public immutable rewardToken;
    uint256 public immutable tokensPerXP;

    struct Profile {
        uint256 xp;
        uint64 lastDay;
        uint32 streak;
        uint32 bonusClaims;
    }
    mapping(address => Profile) public profiles;

    event CheckedIn(address indexed user, uint32 streak, uint256 xpGained);
    event XPWithdrawn(address indexed user, uint256 xp, uint256 tokens);
    event StreakBonusClaimed(address indexed user, uint32 streak);

    constructor(IERC20 _token, uint256 _tokensPerXP) {
        rewardToken = _token;
        tokensPerXP = _tokensPerXP;
    }

    /// @dev Resets the streak if a whole day was missed. Computed on demand, no timers.
    function _updateXP(address who) internal {
        Profile storage p = profiles[who];
        uint64 today = uint64(block.timestamp / DAY);
        if (p.lastDay != 0 && today > p.lastDay + 1) {
            p.streak = 0;
        }
    }

    function checkIn() external {
        _updateXP(msg.sender);
        Profile storage p = profiles[msg.sender];
        uint64 today = uint64(block.timestamp / DAY);
        if (p.lastDay == today) revert AlreadyCheckedIn(today);
        p.streak += 1;
        p.lastDay = today;
        uint256 mult = PRECISION + (uint256(p.streak) * PRECISION) / 10;
        if (mult > MAX_MULTIPLIER) mult = MAX_MULTIPLIER;
        uint256 gained = (BASE_XP * mult) / PRECISION;
        p.xp += gained;
        emit CheckedIn(msg.sender, p.streak, gained);
    }

    function claimStreakBonus() external {
        _updateXP(msg.sender);
        Profile storage p = profiles[msg.sender];
        require(p.streak / STREAK_FOR_BONUS > p.bonusClaims, "no bonus due");
        p.bonusClaims += 1;
        if (!rewardToken.transfer(msg.sender, STREAK_BONUS_TOKENS)) revert TransferFailed();
        emit StreakBonusClaimed(msg.sender, p.streak);
    }

    function withdrawXP(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _updateXP(msg.sender);
        Profile storage p = profiles[msg.sender];
        if (p.xp < amount) revert InsufficientXP(p.xp, amount);
        p.xp -= amount;
        uint256 tokens = (amount * tokensPerXP) / PRECISION;
        if (!rewardToken.transfer(msg.sender, tokens)) revert TransferFailed();
        emit XPWithdrawn(msg.sender, amount, tokens);
    }
}
