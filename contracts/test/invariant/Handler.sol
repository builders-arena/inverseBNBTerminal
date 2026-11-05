// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {InverseEngine} from "../../src/core/InverseEngine.sol";
import {InverseVault} from "../../src/core/InverseVault.sol";
import {PriceOracle} from "../../src/oracle/PriceOracle.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives random LP flows, trades, and price moves for the solvency invariant.
contract Handler is Test {
    InverseEngine public engine;
    InverseVault public vault;
    PriceOracle public oracle;
    MockV2Pair public pair;
    MockERC20 public token;
    MockERC20 public collateral;

    uint112 constant R_TOKEN = 1_000_000 ether;

    address lp = makeAddr("h_lp");
    address trader = makeAddr("h_trader");

    uint256[] public openIds;

    constructor(
        InverseEngine e,
        InverseVault v,
        PriceOracle o,
        MockV2Pair p,
        MockERC20 t
    ) {
        engine = e;
        vault = v;
        oracle = o;
        pair = p;
        token = t;
        collateral = MockERC20(address(vault.asset()));
        vm.deal(lp, 1_000_000 ether);
        vm.deal(trader, 1_000_000 ether);
        collateral.mint(lp, 1_000_000 ether);
        collateral.mint(trader, 1_000_000 ether);
        vm.prank(lp);
        collateral.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        collateral.approve(address(engine), type(uint256).max);
    }

    function deposit(uint256 amt) public {
        amt = bound(amt, 1 ether, 1000 ether);
        vm.prank(lp);
        try vault.deposit(amt) {} catch {}
    }

    function withdrawFlow(uint256 shares) public {
        uint256 bal = vault.sharesOf(lp);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(lp);
        try vault.requestWithdraw(shares) {} catch {
            return;
        }
        vm.warp(block.timestamp + 72 hours);
        vm.prank(lp);
        try vault.withdraw() {} catch {}
    }

    function open(uint256 amt, bool isLong) public {
        amt = bound(amt, 0.01 ether, 0.5 ether);
        vm.prank(trader);
        try engine.openPosition(amt, address(token), isLong, 2, 0, 0) returns (uint256 id) {
            openIds.push(id);
        } catch {}
    }

    function close(uint256 idx) public {
        if (openIds.length == 0) return;
        idx = bound(idx, 0, openIds.length - 1);
        uint256 id = openIds[idx];
        vm.warp(block.timestamp + 61);
        pair.sync();
        vm.prank(trader);
        try engine.closePosition(id) {} catch {}
    }

    function reprice(uint256 newWbnb) public {
        newWbnb = bound(newWbnb, 60 ether, 180 ether);
        pair.setReserves(R_TOKEN, uint112(newWbnb));
        oracle.snapshot(address(token));
        for (uint256 i = 0; i < 7; i++) {
            vm.warp(block.timestamp + 5 minutes);
            pair.sync();
            oracle.snapshot(address(token));
        }
    }
}
