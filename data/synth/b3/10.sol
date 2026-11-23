// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Loyalty punch card. One punch per cooldown; punches expire if the card is idle too long.
contract PunchCard {
    uint256 public constant COOLDOWN = 6 hours;
    uint256 public constant IDLE_EXPIRY = 30 days;
    uint256 public constant PUNCHES_PER_REWARD = 10;
    uint256 public constant REWARD_VALUE = 2e18;

    IERC20 public immutable token;

    struct Card {
        uint32 punches;
        uint64 lastPunch;
        uint256 collateral;
    }
    mapping(address => Card) public cards;

    event Punched(address indexed user, uint32 punches);
    event CollateralAdded(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event RewardRedeemed(address indexed user, uint256 rewards, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
    }

    /// @dev Expires punches on an idle card. Runs before every read or write of the card.
    function _pokeLoyalty(address who) internal {
        Card storage c = cards[who];
        if (c.lastPunch != 0 && block.timestamp > uint256(c.lastPunch) + IDLE_EXPIRY) {
            c.punches = 0;
        }
    }

    function punchCard() external {
        _pokeLoyalty(msg.sender);
        Card storage c = cards[msg.sender];
        require(block.timestamp >= uint256(c.lastPunch) + COOLDOWN, "cooldown active");
        c.punches += 1;
        c.lastPunch = uint64(block.timestamp);
        emit Punched(msg.sender, c.punches);
    }

    function addCollateral(uint256 amount) external {
        _pokeLoyalty(msg.sender);
        Card storage c = cards[msg.sender];
        c.collateral += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit CollateralAdded(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external {
        _pokeLoyalty(msg.sender);
        Card storage c = cards[msg.sender];
        require(c.collateral >= amount, "insufficient collateral");
        c.collateral -= amount;
        require(token.transfer(msg.sender, amount), "push failed");
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function redeemRewards(uint256 rewards) external {
        _pokeLoyalty(msg.sender);
        Card storage c = cards[msg.sender];
        uint256 needed = rewards * PUNCHES_PER_REWARD;
        require(c.punches >= needed, "not enough punches");
        c.punches -= uint32(needed);
        uint256 amount = rewards * REWARD_VALUE;
        require(token.transfer(msg.sender, amount), "payout failed");
        emit RewardRedeemed(msg.sender, rewards, amount);
    }
}
