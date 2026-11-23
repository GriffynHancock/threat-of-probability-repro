// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Season pass. Deposits buy XP in a packed per-user record; XP unlocks tiers that pay rewards.
contract SeasonPass {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant SEASON_LENGTH = 90 days;
    uint256 public constant XP_PER_TIER = 1_000;
    uint256 public constant TIER_REWARD = 25 * PRECISION;
    uint256 public immutable xpPerToken;

    IERC20 public immutable token;

    /// @dev Packed into one storage slot.
    struct Pass {
        uint128 xp;
        uint64 tiersClaimed;
        uint64 seasonEnds;
    }

    mapping(address => Pass) private _passes;
    mapping(address => uint256) public deposits;

    event PassBought(address indexed user, uint256 amount, uint256 xpGained);
    event TierClaimed(address indexed user, uint256 tiers, uint256 reward);
    event DepositWithdrawn(address indexed user, uint256 amount);

    constructor(IERC20 _token, uint256 _xpPerToken) {
        token = _token;
        xpPerToken = _xpPerToken;
    }

    function passOf(address who) external view returns (uint128 xp, uint64 tiersClaimed, uint64 seasonEnds) {
        Pass storage p = _passes[who];
        return (p.xp, p.tiersClaimed, p.seasonEnds);
    }

    /// @dev Expires a lapsed season: XP and claimed tiers reset. Called before any read or write.
    function _tallyPassXp(address who) internal {
        Pass storage p = _passes[who];
        if (p.seasonEnds != 0 && block.timestamp >= p.seasonEnds) {
            p.xp = 0;
            p.tiersClaimed = 0;
            p.seasonEnds = 0;
        }
    }

    function buyPass(uint256 amount) external {
        require(amount > 0, "zero amount");
        _tallyPassXp(msg.sender);
        Pass storage p = _passes[msg.sender];
        if (p.seasonEnds == 0) {
            p.seasonEnds = uint64(block.timestamp + SEASON_LENGTH);
        }
        uint256 gained = (amount * xpPerToken) / PRECISION;
        p.xp += uint128(gained);
        deposits[msg.sender] += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit PassBought(msg.sender, amount, gained);
    }

    function claimTierRewards() external {
        _tallyPassXp(msg.sender);
        Pass storage p = _passes[msg.sender];
        uint256 tiersReached = uint256(p.xp) / XP_PER_TIER;
        uint256 owed = tiersReached - p.tiersClaimed;
        require(owed > 0, "no tiers");
        p.tiersClaimed = uint64(tiersReached);
        uint256 reward = owed * TIER_REWARD;
        require(token.transfer(msg.sender, reward), "push failed");
        emit TierClaimed(msg.sender, owed, reward);
    }

    function withdrawDeposit(uint256 amount) external {
        _tallyPassXp(msg.sender);
        require(deposits[msg.sender] >= amount, "insufficient deposit");
        deposits[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "push failed");
        emit DepositWithdrawn(msg.sender, amount);
    }
}
