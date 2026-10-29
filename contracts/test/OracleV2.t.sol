// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract OracleV2Test is Base {
    function test_route_isV2_whenNoV3() public view {
        assertTrue(oracle.isSupported(address(token)));
        assertEq(uint256(oracle.status(address(token)).route), uint256(IPriceOracle.Route.V2));
    }

    function test_warming_revertsBeforeAnchor() public {
        oracle.snapshot(address(token)); // single snapshot, no anchor yet
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleWarming.selector, address(token), block.timestamp + 5 minutes));
        oracle.getPrice(address(token));
    }

    function test_tradable_afterWindow() public {
        _warmV2();
        uint256 p = oracle.getPrice(address(token));
        // constant reserves => TWAP == spot, within 1 wei of fixed-point rounding
        assertApproxEqAbs(p, _expectedPrice(R_TOKEN, R_WBNB), 2);
    }

    function test_twap_tracksConstantPrice() public {
        _warmV2();
        assertApproxEqAbs(oracle.getPrice(address(token)), 1e14, 2);
    }

    function test_stale_revertsWhenNewestOld() public {
        _warmV2();
        // Let the newest snapshot age past MAX_SNAPSHOT_AGE without a refresh.
        vm.warp(block.timestamp + 6 minutes);
        pair.sync();
        vm.expectRevert(abi.encodeWithSelector(Errors.Stale.selector, address(token), 6 minutes));
        oracle.getPrice(address(token));
    }

    function test_lowLiquidity_reverts() public {
        // Drop WBNB reserve below the 50 BNB floor.
        pair.setReserves(R_TOKEN, 40 ether);
        _warmV2();
        vm.expectRevert(abi.encodeWithSelector(Errors.LowLiquidity.selector, address(token), uint256(40 ether)));
        oracle.getPrice(address(token));
    }

    function test_deviation_reverts_whenSpotJumps() public {
        _warmV2(); // TWAP anchored at 100 BNB reserve
        // Jump spot +40% (deviation > 25%) without letting the TWAP catch up.
        pair.setReserves(R_TOKEN, 140 ether);
        oracle.snapshot(address(token)); // fresh newest so it is not Stale
        vm.expectRevert();
        oracle.getPrice(address(token));
    }

    function test_snapshotGap_noDuplicateWithinGap() public {
        oracle.snapshot(address(token));
        uint256 c1 = oracle.snapshotCount(address(token));
        oracle.snapshot(address(token)); // same block, within 60s gap -> no new snapshot
        assertEq(oracle.snapshotCount(address(token)), c1);
        vm.warp(block.timestamp + 61);
        pair.sync();
        oracle.snapshot(address(token));
        assertEq(oracle.snapshotCount(address(token)), c1 + 1);
    }

    function test_pairReserveWbnb_reportsWbnbSide() public view {
        assertEq(oracle.pairReserveWbnb(address(token)), R_WBNB);
    }

    function test_halt_isGuardianOnly() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, trader));
        oracle.setHalted(address(token), true);

        oracle.setHalted(address(token), true);
        assertTrue(oracle.halted(address(token)));
    }

    function test_unsupported_revertsForUnknownToken() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, unknown));
        oracle.getPrice(unknown);
    }
}
