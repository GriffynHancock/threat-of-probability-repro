// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface ITokenIO {
    function balanceOf(address holder) external view returns (uint256);
    function transfer(address recipient, uint256 value) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 value) external returns (bool);
}

error NotSteward();
error NothingToLeave();
error NothingToClaim();
error TokenMoveFailed();

/// Open-ended staking hall. The steward sets a flat emission rate; members
/// join and leave at will. Global index `rptStored` advances whenever the
/// rate or the membership changes, and each member's credit is recalculated
/// against it before their balance moves.
contract StakeHall {
    uint256 private constant FIXED = 1e18;

    ITokenIO public immutable memberToken;
    ITokenIO public immutable yieldToken;
    address public steward;

    uint256 public flatRate;
    uint256 public rptStored;
    uint256 public rptUpdated;
    uint256 public totalJoined;

    mapping(address => uint256) public joinedAmount;
    mapping(address => uint256) public rptUserPaid;
    mapping(address => uint256) public pendingYield;

    event Joined(address indexed member, uint256 amount);
    event Left(address indexed member, uint256 amount);
    event YieldClaimed(address indexed member, uint256 amount);
    event RateSet(uint256 oldRate, uint256 newRate);

    constructor(ITokenIO _member, ITokenIO _yield, uint256 _rate) {
        memberToken = _member;
        yieldToken = _yield;
        steward = msg.sender;
        flatRate = _rate;
        rptUpdated = block.timestamp;
    }

    modifier onlySteward() {
        if (msg.sender != steward) revert NotSteward();
        _;
    }

    function rptCurrent() public view returns (uint256) {
        if (totalJoined == 0) {
            return rptStored;
        }
        return rptStored + ((block.timestamp - rptUpdated) * flatRate * FIXED) / totalJoined;
    }

    function claimable(address member) public view returns (uint256) {
        return pendingYield[member] + (joinedAmount[member] * (rptCurrent() - rptUserPaid[member])) / FIXED;
    }

    function join(uint256 amount) external {
        _refreshRewards(msg.sender);
        require(amount != 0, "StakeHall: amount");

        joinedAmount[msg.sender] += amount;
        totalJoined += amount;

        if (!memberToken.transferFrom(msg.sender, address(this), amount)) revert TokenMoveFailed();
        emit Joined(msg.sender, amount);
    }

    function leave() external {
        uint256 held = joinedAmount[msg.sender];
        if (held == 0) revert NothingToLeave();
        _refreshRewards(msg.sender);

        joinedAmount[msg.sender] = 0;
        totalJoined -= held;

        if (!memberToken.transfer(msg.sender, held)) revert TokenMoveFailed();
        emit Left(msg.sender, held);
    }

    function claimAll() external {
        _refreshRewards(msg.sender);

        uint256 due = pendingYield[msg.sender];
        if (due == 0) revert NothingToClaim();
        pendingYield[msg.sender] = 0;

        if (!yieldToken.transfer(msg.sender, due)) revert TokenMoveFailed();
        emit YieldClaimed(msg.sender, due);
    }

    function setFlatRate(uint256 newRate) external onlySteward {
        _refreshRewards(address(0));
        emit RateSet(flatRate, newRate);
        flatRate = newRate;
    }

    /// Settles global accrual to now and, for a non-zero member, folds the
    /// member's share into pendingYield. Must run before any balance change.
    function _refreshRewards(address member) internal {
        rptStored = rptCurrent();
        rptUpdated = block.timestamp;

        if (member != address(0)) {
            pendingYield[member] = claimable(member);
            rptUserPaid[member] = rptStored;
        }
    }
}
