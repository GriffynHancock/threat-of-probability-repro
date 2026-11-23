// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20, IERC20} from "../src/MockERC20.sol";
import {StakingPoolClean} from "../src/StakingPoolClean.sol";
import {StakingPoolBugged} from "../src/StakingPoolBugged.sol";

interface IPool {
    function stake(uint256) external;
    function unstake(uint256) external;
    function claim() external returns (uint256);
    function totalStaked() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function accRewardPerShare() external view returns (uint256);
}

/// @notice Drives the pool with bounded random actions and keeps an INDEPENDENT
///         ghost ledger of what each actor is actually entitled to:
///         the time-weighted integral of (their balance / total) * rate.
contract Handler is Test {
    uint256 public constant RATE = 1e18;

    IPool public pool;
    MockERC20 public stakingToken;
    address[3] public actors;

    // ghost ledger
    mapping(address => uint256) public ghostBal;
    mapping(address => uint256) public ghostEarned;
    mapping(address => uint256) public claimed;
    uint256 public ghostTotal;
    uint256 public ghostLastUpdate;
    uint256 public totalClaimed;
    uint256 public startTime;

    constructor(IPool _pool, MockERC20 _stakingToken, address[3] memory _actors) {
        pool = _pool;
        stakingToken = _stakingToken;
        actors = _actors;
        ghostLastUpdate = block.timestamp;
        startTime = block.timestamp;
    }

    function _ghostAccrue() internal {
        uint256 elapsed = block.timestamp - ghostLastUpdate;
        if (elapsed > 0 && ghostTotal > 0) {
            for (uint256 i = 0; i < actors.length; i++) {
                ghostEarned[actors[i]] += (elapsed * RATE * ghostBal[actors[i]]) / ghostTotal;
            }
        }
        ghostLastUpdate = block.timestamp;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1e18, 1_000_000e18);
        if (stakingToken.balanceOf(a) < amount) return;
        _ghostAccrue();
        vm.prank(a);
        pool.stake(amount);
        ghostBal[a] += amount;
        ghostTotal += amount;
    }

    function unstake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        if (ghostBal[a] == 0) return;
        amount = bound(amount, 1, ghostBal[a]);
        _ghostAccrue();
        vm.prank(a);
        pool.unstake(amount);
        ghostBal[a] -= amount;
        ghostTotal -= amount;
    }

    function claim(uint256 seed) external {
        address a = _actor(seed);
        _ghostAccrue();
        vm.prank(a);
        uint256 got = pool.claim();
        claimed[a] += got;
        totalClaimed += got;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 7 days);
        _ghostAccrue();
        vm.warp(block.timestamp + secs);
    }

    function sumGhostBalances() external view returns (uint256 s) {
        for (uint256 i = 0; i < actors.length; i++) s += ghostBal[actors[i]];
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

abstract contract InvariantBase is StdInvariant, Test {
    uint256 constant RATE = 1e18;
    Handler handler;
    IPool pool;
    MockERC20 stakingToken;
    MockERC20 rewardToken;
    address[3] actors;

    function _deploy(IERC20 s, IERC20 r, uint256 rate) internal virtual returns (address);

    function setUp() public {
        vm.warp(1_700_000_000);
        stakingToken = new MockERC20();
        rewardToken = new MockERC20();
        pool = IPool(_deploy(IERC20(address(stakingToken)), IERC20(address(rewardToken)), RATE));
        rewardToken.mint(address(pool), 1e30);

        actors = [address(0xA11CE), address(0xB0B), address(0xBAD)];
        handler = new Handler(pool, stakingToken, actors);
        for (uint256 i = 0; i < actors.length; i++) {
            stakingToken.mint(actors[i], 10_000_000e18);
            vm.prank(actors[i]);
            stakingToken.approve(address(pool), type(uint256).max);
        }
        targetContract(address(handler));
    }

    // ================================================================
    // THE INVARIANTS A COMPETENT TEAM ACTUALLY WRITES.
    // Every one of these passes on BOTH the clean and the bugged pool.
    // ================================================================

    /// @notice accounting consistency -- the first thing anyone asserts
    function invariant_A_totalStakedEqualsSumOfBalances() public view {
        uint256 s;
        for (uint256 i = 0; i < actors.length; i++) s += pool.balanceOf(actors[i]);
        assertEq(pool.totalStaked(), s, "totalStaked != sum(balances)");
    }

    /// @notice principal is always recoverable
    function invariant_B_principalBackedByTokens() public view {
        assertLe(pool.totalStaked(), stakingToken.balanceOf(address(pool)),
                 "pool owes more principal than it holds");
    }

    /// @notice the reward index never goes backwards
    uint256 private lastAcc;
    function invariant_C_accumulatorMonotonic() public {
        uint256 acc = pool.accRewardPerShare();
        assertGe(acc, lastAcc, "accumulator went backwards");
        lastAcc = acc;
    }

    /// @notice the pool never pays out more than it emitted  (CONSERVATION)
    function invariant_D_noInflation() public view {
        uint256 emitted = (block.timestamp - handler.startTime()) * RATE;
        assertLe(handler.totalClaimed(), emitted + 1e18,
                 "paid out more than was emitted");
    }

    // ================================================================
    // THE ONE THAT CATCHES IT.
    // Per-actor, time-weighted entitlement: you may only be paid for the
    // integral of (your balance / total) * rate over time you were staked.
    // ================================================================
    function invariant_E_rewardProportionalToBalanceAndTime() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            uint256 entitled = handler.ghostEarned(a);
            uint256 paid = handler.claimed(a);
            // generous slack for integer truncation
            uint256 ceiling = entitled + (entitled / 100) + 10e18;
            assertLe(paid, ceiling,
                     "actor paid more than balance x time entitles them to");
        }
    }
}

contract CleanInvariantTest is InvariantBase {
    function _deploy(IERC20 s, IERC20 r, uint256 rate) internal override returns (address) {
        return address(new StakingPoolClean(s, r, rate));
    }
}

contract BuggedInvariantTest is InvariantBase {
    function _deploy(IERC20 s, IERC20 r, uint256 rate) internal override returns (address) {
        return address(new StakingPoolBugged(s, r, rate));
    }
}
