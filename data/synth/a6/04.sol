// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// Linear vesting ledger. No deposits: the treasury grants schedules up front and
/// each grant accrues pro rata to time. Release settles the caller's grant to the
/// vested amount and transfers the difference.
contract LinearVestingLedger {
    error NotAdmin();
    error AlreadyGranted(address beneficiary);
    error InvalidSchedule();
    error NoGrant();
    error NothingVested();
    error TransferFailed();

    event Granted(address indexed beneficiary, uint128 total, uint64 start, uint64 duration);
    event Released(address indexed beneficiary, uint256 amount, uint256 releasedTotal);
    event Checkpointed(address indexed beneficiary, uint256 vestedNow);
    event AdminMoved(address indexed from, address indexed to);

    struct Grant {
        uint128 total;
        uint128 released;
        uint64 start;
        uint64 duration;
    }

    IERC20Transfer public immutable token;
    address public admin;
    uint256 public totalGranted;

    mapping(address => Grant) public grants;

    constructor(IERC20Transfer token_) {
        token = token_;
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function moveAdmin(address next) external onlyAdmin {
        emit AdminMoved(admin, next);
        admin = next;
    }

    /// Creates a grant. Does not touch any existing grant's released amount.
    function grantSchedule(address beneficiary, uint128 total, uint64 start, uint64 duration) external onlyAdmin {
        if (duration == 0 || total == 0) revert InvalidSchedule();
        if (grants[beneficiary].total != 0) revert AlreadyGranted(beneficiary);
        grants[beneficiary] = Grant({total: total, released: 0, start: start, duration: duration});
        totalGranted = totalGranted + total;
        emit Granted(beneficiary, total, start, duration);
    }

    function release() external returns (uint256 amount) {
        amount = _releaseVested(msg.sender);
        if (amount == 0) revert NothingVested();
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        emit Released(msg.sender, amount, grants[msg.sender].released);
    }

    /// Brings a beneficiary's record up to the current vesting point without paying out.
    function checkpoint(address beneficiary) external {
        if (grants[beneficiary].total == 0) revert NoGrant();
        _releaseVested(beneficiary);
        emit Checkpointed(beneficiary, vestedAt(beneficiary, block.timestamp));
    }

    function releasable(address beneficiary) public view returns (uint256) {
        return vestedAt(beneficiary, block.timestamp) - grants[beneficiary].released;
    }

    function vestedAt(address beneficiary, uint256 when) public view returns (uint256) {
        Grant memory g = grants[beneficiary];
        if (g.total == 0 || when <= g.start) return 0;
        uint256 end = uint256(g.start) + uint256(g.duration);
        if (when >= end) return g.total;
        return (uint256(g.total) * (when - g.start)) / g.duration;
    }

    /// Settlement helper: moves the grant's released marker forward to the vested point.
    function _releaseVested(address beneficiary) internal returns (uint256 delta) {
        Grant storage g = grants[beneficiary];
        uint256 vested = vestedAt(beneficiary, block.timestamp);
        if (vested <= g.released) return 0;
        delta = vested - g.released;
        g.released = uint128(vested);
    }
}
