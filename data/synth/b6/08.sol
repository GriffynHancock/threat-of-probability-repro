// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Restaking with a governor-applied slashing index. Shares are rescaled lazily on touch.
contract DelegationWithSlashing {
    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 public constant UNBOND_DELAY = 14 days;

    struct Delegation {
        uint256 shares;
        uint256 slashSnap;
    }

    struct Unbond {
        uint256 amount;
        uint256 unlockAt;
    }

    IERC20 public immutable token;
    address public immutable governor;
    uint256 public slashIndex = ONE;
    uint256 public totalRestaked;

    mapping(address => Delegation) public delegations;
    mapping(address => Unbond) public unbonds;

    event Restaked(address indexed staker, uint256 amount);
    event SlashApplied(uint256 bps, uint256 newIndex);
    event UnbondRequested(address indexed staker, uint256 amount, uint256 unlockAt);
    event UnbondClaimed(address indexed staker, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        governor = msg.sender;
    }

    function _applySlashIndex(address who) internal {
        Delegation storage d = delegations[who];
        if (d.slashSnap == 0) {
            d.slashSnap = slashIndex;
            return;
        }
        if (d.slashSnap == slashIndex) return;
        d.shares = (d.shares * slashIndex) / d.slashSnap;
        d.slashSnap = slashIndex;
    }

    function slash(uint256 bps) external {
        require(msg.sender == governor, "not governor");
        require(bps <= BPS, "bps");
        slashIndex = (slashIndex * (BPS - bps)) / BPS;
        require(slashIndex > 0, "index");
        emit SlashApplied(bps, slashIndex);
    }

    function restake(uint256 amount) external {
        require(amount > 0, "zero");
        _applySlashIndex(msg.sender);
        Delegation storage d = delegations[msg.sender];
        d.shares += amount;
        totalRestaked += amount;
        emit Restaked(msg.sender, amount);
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
    }

    function requestUnrestake(uint256 amount) external {
        require(amount > 0, "zero");
        _applySlashIndex(msg.sender);
        Delegation storage d = delegations[msg.sender];
        require(d.shares >= amount, "insufficient");
        d.shares -= amount;
        Unbond storage u = unbonds[msg.sender];
        u.amount += amount;
        u.unlockAt = block.timestamp + UNBOND_DELAY;
        emit UnbondRequested(msg.sender, amount, u.unlockAt);
    }

    function claimUnbond() external returns (uint256 amount) {
        Unbond storage u = unbonds[msg.sender];
        amount = u.amount;
        require(amount > 0, "none");
        require(block.timestamp >= u.unlockAt, "locked");
        u.amount = 0;
        u.unlockAt = 0;
        totalRestaked -= amount;
        emit UnbondClaimed(msg.sender, amount);
        require(token.transfer(msg.sender, amount), "xfer");
    }

    function effectiveShares(address who) external view returns (uint256) {
        Delegation storage d = delegations[who];
        if (d.slashSnap == 0) return d.shares;
        return (d.shares * slashIndex) / d.slashSnap;
    }
}
