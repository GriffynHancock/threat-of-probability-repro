// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Trait loadouts. Each loadout's rarity score earns yield per second; equipping changes the score.
contract TraitLoadout {
    error BadSlot(uint8 slot);
    error UnknownTrait(uint8 trait);
    error NotAdmin();

    uint256 private constant PRECISION = 1e18;
    uint8 public constant SLOTS = 3;

    IERC20 public immutable rewardToken;
    uint256 public immutable yieldPerScoreSecond;
    address public immutable admin;

    mapping(uint8 => uint64) public rarity;

    struct Loadout {
        uint8[3] traits;
        uint64 score;
        uint64 lastWeigh;
        uint256 earned;
    }
    mapping(address => Loadout) public loadouts;

    event RaritySet(uint8 trait, uint64 score);
    event TraitEquipped(address indexed user, uint8 slot, uint8 trait, uint64 score);
    event SlotCleared(address indexed user, uint8 slot);
    event ShareClaimed(address indexed user, uint256 amount);

    constructor(IERC20 _reward, uint256 _yield) {
        rewardToken = _reward;
        yieldPerScoreSecond = _yield;
        admin = msg.sender;
    }

    /// @notice Rarity is set once per trait, so a loadout's score can never be re-priced under its holder.
    function setRarity(uint8 trait, uint64 score) external {
        if (msg.sender != admin) revert NotAdmin();
        require(trait != 0 && score > 0 && rarity[trait] == 0, "bad rarity");
        rarity[trait] = score;
        emit RaritySet(trait, score);
    }

    /// @dev Credits yield at the current score, then restamps. Must run before the score changes.
    function _weighRarity(address who) internal {
        Loadout storage l = loadouts[who];
        if (l.lastWeigh != 0) {
            uint256 dt = block.timestamp - l.lastWeigh;
            l.earned += (uint256(l.score) * yieldPerScoreSecond * dt) / PRECISION;
        }
        l.lastWeigh = uint64(block.timestamp);
    }

    function equipTrait(uint8 slot, uint8 trait) external {
        if (slot >= SLOTS) revert BadSlot(slot);
        if (rarity[trait] == 0) revert UnknownTrait(trait);
        _weighRarity(msg.sender);
        Loadout storage l = loadouts[msg.sender];
        uint8 old = l.traits[slot];
        l.traits[slot] = trait;
        l.score += rarity[trait];
        l.score -= rarity[old];
        emit TraitEquipped(msg.sender, slot, trait, l.score);
    }

    function clearSlot(uint8 slot) external {
        if (slot >= SLOTS) revert BadSlot(slot);
        _weighRarity(msg.sender);
        Loadout storage l = loadouts[msg.sender];
        uint8 old = l.traits[slot];
        l.score -= rarity[old];
        l.traits[slot] = 0;
        emit SlotCleared(msg.sender, slot);
    }

    function claimShare() external {
        _weighRarity(msg.sender);
        Loadout storage l = loadouts[msg.sender];
        uint256 amount = l.earned;
        require(amount > 0, "nothing");
        l.earned = 0;
        require(rewardToken.transfer(msg.sender, amount), "push failed");
        emit ShareClaimed(msg.sender, amount);
    }
}
