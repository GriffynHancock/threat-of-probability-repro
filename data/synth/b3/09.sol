// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Referral points. Referrers earn bonus points for each invitee they confirm.
contract ReferralPoints {
    error SelfReferral();
    error AlreadyReferred(address invitee);
    error NotReferredBy(address invitee, address referrer);
    error AlreadyConfirmed(address invitee);
    error InsufficientBonus(uint256 have, uint256 want);

    uint256 public constant BONUS_PER_INVITE = 500;

    mapping(address => address) public referrerOf;
    mapping(address => bool) public confirmed;
    mapping(address => uint256) public invitesOf;
    mapping(address => uint256) public settledInvites;
    mapping(address => uint256) public bonusOwed;
    mapping(address => uint256) public bonusClaimed;

    event ReferrerSet(address indexed invitee, address indexed referrer);
    event InviteConfirmed(address indexed referrer, address indexed invitee);
    event BonusClaimed(address indexed user, uint256 amount);

    /// @dev Converts confirmed invites not yet paid into bonus points.
    function _settleReferralBonus(address who) internal {
        uint256 fresh = invitesOf[who] - settledInvites[who];
        if (fresh > 0) {
            bonusOwed[who] += fresh * BONUS_PER_INVITE;
            settledInvites[who] = invitesOf[who];
        }
    }

    function setReferrer(address referrer) external {
        if (referrer == msg.sender) revert SelfReferral();
        if (referrerOf[msg.sender] != address(0)) revert AlreadyReferred(msg.sender);
        referrerOf[msg.sender] = referrer;
        emit ReferrerSet(msg.sender, referrer);
    }

    function confirmInvite(address invitee) external {
        _settleReferralBonus(msg.sender);
        if (referrerOf[invitee] != msg.sender) revert NotReferredBy(invitee, msg.sender);
        if (confirmed[invitee]) revert AlreadyConfirmed(invitee);
        confirmed[invitee] = true;
        invitesOf[msg.sender] += 1;
        emit InviteConfirmed(msg.sender, invitee);
    }

    function claimReferralBonus() external {
        _settleReferralBonus(msg.sender);
        uint256 amount = bonusOwed[msg.sender] - bonusClaimed[msg.sender];
        require(amount > 0, "nothing to claim");
        bonusClaimed[msg.sender] += amount;
        emit BonusClaimed(msg.sender, amount);
    }

    function spendBonus(uint256 amount) external {
        _settleReferralBonus(msg.sender);
        uint256 avail = bonusOwed[msg.sender] - bonusClaimed[msg.sender];
        if (avail < amount) revert InsufficientBonus(avail, amount);
        bonusOwed[msg.sender] -= amount;
    }
}
