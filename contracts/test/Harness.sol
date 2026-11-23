// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20, IERC20} from "../src/MockERC20.sol";
import {StakingPoolClean} from "../src/StakingPoolClean.sol";
import {StakingPoolBugged} from "../src/StakingPoolBugged.sol";

interface Vm {
    function warp(uint256) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
    function label(address, string calldata) external;
}

interface IStakingPool {
    function stake(uint256) external;
    function unstake(uint256) external;
    function claim() external returns (uint256);
    function earned(address) external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

abstract contract PoolTestBase {
    event log_named_uint(string key, uint256 val);
    event log_named_string(string key, string val);

    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 constant EPOCH = 7 days;
    uint256 constant RATE = 1e18;          // 1 reward token per second
    uint256 constant HONEST_STAKE = 1_000e18;
    uint256 constant FLASH_STAKE = 10_000_000e18;
    uint256 constant REWARD_FUNDING = 10_000_000e18;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant ATTACKER = address(0xBAD);

    MockERC20 stakingToken;
    MockERC20 rewardToken;
    IStakingPool pool;

    /// @dev implemented by the Clean / Bugged subclasses
    function _deploy(IERC20 s, IERC20 r, uint256 rate) internal virtual returns (address);

    function setUp() public {
        vm.warp(1_700_000_000);
        stakingToken = new MockERC20();
        rewardToken = new MockERC20();
        pool = IStakingPool(_deploy(IERC20(address(stakingToken)), IERC20(address(rewardToken)), RATE));

        rewardToken.mint(address(pool), REWARD_FUNDING);

        address[3] memory actors = [ALICE, BOB, ATTACKER];
        for (uint256 i = 0; i < actors.length; i++) {
            stakingToken.mint(actors[i], FLASH_STAKE);
            vm.startPrank(actors[i]);
            stakingToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _stake(address who, uint256 amt) internal {
        vm.startPrank(who);
        pool.stake(amt);
        vm.stopPrank();
    }

    function _unstake(address who, uint256 amt) internal {
        vm.startPrank(who);
        pool.unstake(amt);
        vm.stopPrank();
    }

    function _claim(address who) internal returns (uint256) {
        vm.startPrank(who);
        uint256 got = pool.claim();
        vm.stopPrank();
        return got;
    }

    function _assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, what);
    }

    // ------------------------------------------------------------------
    // THE ORDINARY CI SUITE. Every one of these passes on BOTH contracts.
    // ------------------------------------------------------------------

    function test_StakeIncreasesBalanceAndTotal() public {
        _stake(ALICE, HONEST_STAKE);
        _assertEq(pool.balanceOf(ALICE), HONEST_STAKE, "balance wrong");
        _assertEq(pool.totalStaked(), HONEST_STAKE, "total wrong");
    }

    function test_UnstakeReturnsPrincipal() public {
        _stake(ALICE, HONEST_STAKE);
        uint256 before = stakingToken.balanceOf(ALICE);
        _unstake(ALICE, HONEST_STAKE);
        _assertEq(stakingToken.balanceOf(ALICE) - before, HONEST_STAKE, "principal not returned");
        _assertEq(pool.totalStaked(), 0, "total not zeroed");
    }

    function test_SingleStakerAccruesWholeEpoch() public {
        _stake(ALICE, HONEST_STAKE);
        vm.warp(block.timestamp + EPOCH);
        uint256 got = _claim(ALICE);
        _assertEq(got, EPOCH * RATE, "single staker reward wrong");
    }

    function test_TwoStakersSplitEqually() public {
        _stake(ALICE, HONEST_STAKE);
        _stake(BOB, HONEST_STAKE);
        vm.warp(block.timestamp + EPOCH);
        uint256 a = _claim(ALICE);
        uint256 b = _claim(BOB);
        _assertEq(a, b, "split not equal");
        _assertEq(a + b, EPOCH * RATE, "split does not sum to emission");
    }

    function test_InvariantTotalStakedEqualsSumOfBalances() public {
        _stake(ALICE, HONEST_STAKE);
        _stake(BOB, HONEST_STAKE * 3);
        vm.warp(block.timestamp + EPOCH / 2);
        _unstake(BOB, HONEST_STAKE);
        _assertEq(
            pool.totalStaked(),
            pool.balanceOf(ALICE) + pool.balanceOf(BOB),
            "totalStaked != sum(balances)"
        );
    }

    function test_CannotStakeZero() public {
        vm.startPrank(ALICE);
        vm.expectRevert("zero amount");
        pool.stake(0);
        vm.stopPrank();
    }

    function test_CannotUnstakeMoreThanStaked() public {
        _stake(ALICE, HONEST_STAKE);
        vm.startPrank(ALICE);
        vm.expectRevert("insufficient stake");
        pool.unstake(HONEST_STAKE + 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // THE EPOCH-BOUNDARY TEST. This is the one nobody writes.
    // ------------------------------------------------------------------

    /// @dev Alice stakes and nothing touches the pool for a whole epoch.
    ///      At the very end of the epoch the attacker flash-stakes, claims,
    ///      and unstakes in one transaction.
    ///      Returns (attackerReward, aliceReward).
    function _runEpochBoundaryAttack() internal returns (uint256, uint256) {
        _stake(ALICE, HONEST_STAKE);
        vm.warp(block.timestamp + EPOCH);

        vm.startPrank(ATTACKER);
        pool.stake(FLASH_STAKE);
        uint256 attackerReward = pool.claim();
        pool.unstake(FLASH_STAKE);
        vm.stopPrank();

        uint256 aliceReward = _claim(ALICE);
        emit log_named_uint("epoch emission (tokens)", (EPOCH * RATE) / 1e18);
        emit log_named_uint("attacker reward (tokens)", attackerReward / 1e18);
        emit log_named_uint("alice reward   (tokens)", aliceReward / 1e18);
        emit log_named_uint("attacker share (bps)", (attackerReward * 10000) / (EPOCH * RATE));
        emit log_named_uint("attacker seconds staked", 0);
        return (attackerReward, aliceReward);
    }
}

contract CleanPoolTest is PoolTestBase {
    function _deploy(IERC20 s, IERC20 r, uint256 rate) internal override returns (address) {
        return address(new StakingPoolClean(s, r, rate));
    }

    function test_EpochBoundaryAttackEarnsNothing() public {
        (uint256 attackerReward, uint256 aliceReward) = _runEpochBoundaryAttack();
        require(attackerReward == 0, "CLEAN: attacker should earn nothing");
        require(aliceReward == EPOCH * RATE, "CLEAN: alice should earn the whole epoch");
    }
}

contract BuggedPoolTest is PoolTestBase {
    function _deploy(IERC20 s, IERC20 r, uint256 rate) internal override returns (address) {
        return address(new StakingPoolBugged(s, r, rate));
    }

    function test_EpochBoundaryAttackDrainsEpoch() public {
        (uint256 attackerReward, uint256 aliceReward) = _runEpochBoundaryAttack();
        uint256 emission = EPOCH * RATE;
        // The attacker was staked for ZERO seconds.
        require(attackerReward * 10000 / emission > 9900, "BUGGED: attacker did not take >99% of the epoch");
        require(aliceReward * 10000 / emission < 100, "BUGGED: alice kept more than 1%");
    }
}
