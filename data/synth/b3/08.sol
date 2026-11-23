// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Tiered membership. Deposits set a tier; each tier earns a rebate rate on the deposit.
contract TieredMembership {
    error BelowMinimum(uint256 need);
    error InsufficientDeposit(uint256 have, uint256 want);

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;
    uint256 public constant TIER_COUNT = 4;

    IERC20 public immutable token;
    uint256[4] public thresholds = [uint256(0), 100e18, 1_000e18, 10_000e18];
    uint256[4] public rebateBps = [uint256(0), 50, 120, 300];

    struct Membership {
        uint256 deposited;
        uint256 rebateOwed;
        uint256 lastAccrual;
        uint8 tier;
    }
    mapping(address => Membership) public members;

    event Registered(address indexed user, uint256 amount, uint8 tier);
    event Withdrawn(address indexed user, uint256 amount);
    event RebateClaimed(address indexed user, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
    }

    function tierFor(uint256 amount) public view returns (uint8 t) {
        for (uint8 i = 0; i < TIER_COUNT; i++) {
            if (amount >= thresholds[i]) t = i;
        }
    }

    /// @dev Accrues rebate at the stored tier, then re-tiers. Settle-before-change.
    function _refreshTier(address who) internal {
        Membership storage m = members[who];
        if (m.lastAccrual != 0 && m.deposited > 0) {
            uint256 dt = block.timestamp - m.lastAccrual;
            m.rebateOwed += (m.deposited * rebateBps[m.tier] * dt) / (BPS * YEAR);
        }
        m.tier = tierFor(m.deposited);
        m.lastAccrual = block.timestamp;
    }

    function register(uint256 amount) external {
        if (amount == 0) revert BelowMinimum(1);
        _refreshTier(msg.sender);
        Membership storage m = members[msg.sender];
        m.deposited += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit Registered(msg.sender, amount, tierFor(m.deposited));
    }

    function withdrawDeposit(uint256 amount) external {
        _refreshTier(msg.sender);
        Membership storage m = members[msg.sender];
        if (m.deposited < amount) revert InsufficientDeposit(m.deposited, amount);
        m.deposited -= amount;
        require(token.transfer(msg.sender, amount), "push failed");
        emit Withdrawn(msg.sender, amount);
    }

    function claimRebate() external {
        _refreshTier(msg.sender);
        Membership storage m = members[msg.sender];
        uint256 amount = m.rebateOwed;
        require(amount > 0, "no rebate");
        m.rebateOwed = 0;
        require(token.transfer(msg.sender, amount), "push failed");
        emit RebateClaimed(msg.sender, amount);
    }
}
