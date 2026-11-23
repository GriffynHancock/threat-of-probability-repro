// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SlashableStakeLedger
/// @notice Shares are reduced by guardian-issued slash events, replayed lazily per position via a cursor.
contract SlashableStakeLedger {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant EXIT_DELAY = 7 days;

    struct Position {
        uint128 shares;
        uint64 cursor;
        uint64 exitAt;
        uint256 rewardDebt;
        uint256 rewardsOwed;
    }

    struct SlashEvent {
        uint64 at;
        uint256 factor;
    }

    IERC20 public immutable token;
    address public immutable guardian;
    uint256 public totalShares;
    uint256 public rewardIndex;

    SlashEvent[] public slashEvents;
    mapping(address => Position) public positions;

    event Staked(address indexed who, uint256 amount);
    event Slashed(uint256 bps, uint256 index);
    event ExitRequested(address indexed who, uint256 exitAt);
    event Exited(address indexed who, uint256 amount);
    event RewardsCollected(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        guardian = msg.sender;
    }

    /// @notice Guardian slashes all stake by `bps` basis points.
    function slash(uint256 bps) external {
        require(msg.sender == guardian, "not guardian");
        require(bps < BPS, "bad bps");
        uint256 factor = PRECISION - (bps * PRECISION) / BPS;
        slashEvents.push(SlashEvent(uint64(block.timestamp), factor));
        totalShares = (totalShares * factor) / PRECISION;
        emit Slashed(bps, slashEvents.length);
    }

    function distributeRewards(uint256 amount) external {
        require(msg.sender == guardian, "not guardian");
        require(totalShares > 0, "no stake");
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        rewardIndex += (amount * PRECISION) / totalShares;
    }

    /// @dev Replays slash events this position has not yet seen.
    function _applyEpochPenalties(address who) internal {
        Position storage p = positions[who];
        uint256 n = slashEvents.length;
        if (p.shares == 0) {
            p.cursor = uint64(n);
            return;
        }
        for (uint256 i = p.cursor; i < n; i++) {
            p.shares = uint128((uint256(p.shares) * slashEvents[i].factor) / PRECISION);
        }
        p.cursor = uint64(n);
    }

    /// @notice Add stake. Replays slashes first so new stake is never penalised retroactively.
    function topUp(uint256 amount) external {
        require(amount > 0, "zero amount");
        require(positions[msg.sender].exitAt == 0, "exiting");
        _applyEpochPenalties(msg.sender);
        Position storage p = positions[msg.sender];
        p.shares += uint128(amount);
        totalShares += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Staked(msg.sender, amount);
    }

    function requestExit() external {
        _applyEpochPenalties(msg.sender);
        Position storage p = positions[msg.sender];
        require(p.shares > 0 && p.exitAt == 0, "bad state");
        p.exitAt = uint64(block.timestamp + EXIT_DELAY);
        emit ExitRequested(msg.sender, p.exitAt);
    }

    /// @notice Withdraw all remaining (post-slash) shares after the exit delay.
    function completeExit() external {
        _applyEpochPenalties(msg.sender);
        Position storage p = positions[msg.sender];
        require(p.exitAt != 0 && block.timestamp >= p.exitAt, "not ready");
        uint256 out = p.shares;
        p.shares -= uint128(out);
        p.exitAt = 0;
        totalShares = out > totalShares ? 0 : totalShares - out;
        require(token.transfer(msg.sender, out), "transfer failed");
        emit Exited(msg.sender, out);
    }

    /// @notice Collect rewards accrued on post-slash shares.
    function collect() external {
        _applyEpochPenalties(msg.sender);
        Position storage p = positions[msg.sender];
        p.rewardsOwed += (uint256(p.shares) * (rewardIndex - p.rewardDebt)) / PRECISION;
        p.rewardDebt = rewardIndex;
        uint256 amount = p.rewardsOwed;
        require(amount > 0, "nothing to collect");
        p.rewardsOwed = 0;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit RewardsCollected(msg.sender, amount);
    }
}
