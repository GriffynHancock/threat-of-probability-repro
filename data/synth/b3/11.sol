// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Game heroes accrue passive power over time. Equipped items add a fixed power bonus.
contract HeroEquip {
    error NoItem(uint256 itemId);
    error NotEquipped(uint256 itemId);
    error NotAdmin();

    uint256 private constant PRECISION = 1e18;
    uint256 public constant PASSIVE_PER_HOUR = 2 * PRECISION;

    IERC20 public immutable goldToken;
    address public immutable admin;

    mapping(uint256 => uint256) public itemPower;
    mapping(address => mapping(uint256 => uint256)) public inventory;
    mapping(address => mapping(uint256 => uint256)) public equippedCount;

    struct Hero {
        uint256 power;
        uint256 gold;
        uint256 lastTs;
    }
    mapping(address => Hero) public heroes;

    event ItemGranted(address indexed to, uint256 itemId);
    event Equipped(address indexed user, uint256 itemId, uint256 power);
    event Unequipped(address indexed user, uint256 itemId, uint256 power);
    event GoldCollected(address indexed user, uint256 amount);

    constructor(IERC20 _gold) {
        goldToken = _gold;
        admin = msg.sender;
    }

    /// @notice Power is set once per item so equipped bonuses can never be reduced under a holder.
    function setItemPower(uint256 itemId, uint256 power) external {
        if (msg.sender != admin) revert NotAdmin();
        require(itemPower[itemId] == 0 && power > 0, "already set");
        itemPower[itemId] = power;
    }

    function grantItem(address to, uint256 itemId) external {
        if (msg.sender != admin) revert NotAdmin();
        if (itemPower[itemId] == 0) revert NoItem(itemId);
        inventory[to][itemId] += 1;
        emit ItemGranted(to, itemId);
    }

    /// @dev Credits passive gold and power for elapsed hours, then stamps the hero.
    function _recalcPower(address who) internal {
        Hero storage h = heroes[who];
        if (h.lastTs != 0) {
            uint256 hours_ = (block.timestamp - h.lastTs) / 1 hours;
            h.gold += hours_ * PASSIVE_PER_HOUR;
            h.power += hours_;
        }
        h.lastTs = block.timestamp;
    }

    function equip(uint256 itemId) external {
        _recalcPower(msg.sender);
        Hero storage h = heroes[msg.sender];
        require(inventory[msg.sender][itemId] > 0, "item not owned");
        inventory[msg.sender][itemId] -= 1;
        equippedCount[msg.sender][itemId] += 1;
        h.power += itemPower[itemId];
        emit Equipped(msg.sender, itemId, h.power);
    }

    function unequip(uint256 itemId) external {
        _recalcPower(msg.sender);
        Hero storage h = heroes[msg.sender];
        if (equippedCount[msg.sender][itemId] == 0) revert NotEquipped(itemId);
        equippedCount[msg.sender][itemId] -= 1;
        inventory[msg.sender][itemId] += 1;
        h.power -= itemPower[itemId];
        emit Unequipped(msg.sender, itemId, h.power);
    }

    function collectGold() external {
        _recalcPower(msg.sender);
        Hero storage h = heroes[msg.sender];
        uint256 amount = h.gold;
        require(amount > 0, "no gold");
        h.gold = 0;
        require(goldToken.transfer(msg.sender, amount), "gold push failed");
        emit GoldCollected(msg.sender, amount);
    }
}
