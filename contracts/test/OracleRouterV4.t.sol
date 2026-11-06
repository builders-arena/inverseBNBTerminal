// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleRouterV4} from "../src/oracle/OracleRouterV4.sol";
import {V4Source} from "../src/oracle/V4Source.sol";
import {V4PoolId} from "../src/libraries/V4PoolId.sol";
import {V3Twap} from "../src/oracle/V3Twap.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockStateView} from "./mocks/MockStateView.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice OracleRouterV4 routing: POOL tokens go to the PriceOracle, Source.V4 tokens go to V4Source,
///         halt flag is router-owned and OR'd into status, and setSource(V4) is gated on a configured
///         V4 source.
contract OracleRouterV4Test is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    address internal constant WETH = address(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    address internal constant V4TOKEN = address(0x00000000000000000000000000000000DeaDBeef);
    address internal constant POOLTOKEN = address(0x00000000000000000000000000000000cafebabe);
    uint256 internal constant FLOOR = 1e16;

    OracleRouterV4 internal router;
    MockPriceOracle internal pool;
    V4Source internal v4;
    MockStateView internal sv;
    V4PoolId.PoolKey internal key;
    bytes32 internal id;

    function setUp() public {
        pool = new MockPriceOracle(42e18, 7e18, FLOOR);
        sv = new MockStateView(address(0x9999));
        v4 = new V4Source(WETH, address(sv), FLOOR, 5 minutes, address(this));
        router = new OracleRouterV4(address(pool), address(v4), address(0), address(0), address(this));

        key = V4PoolId.PoolKey({
            currency0: address(0),
            currency1: V4TOKEN,
            fee: 0,
            tickSpacing: 200,
            hooks: address(0)
        });
        id = V4PoolId.toId(key);
        sv.setPool(id, Q96, 0, uint128(1e24));
        v4.register(V4TOKEN, key);

        router.setSource(V4TOKEN, OracleRouterV4.Source.V4);
        // POOLTOKEN stays Source.POOL (default 0)
    }

    function _warm() internal {
        v4.snapshot(V4TOKEN);
        vm.warp(block.timestamp + 6 minutes);
        v4.snapshot(V4TOKEN);
    }

    function test_Routes_PoolToken_ToPriceOracle() public view {
        assertEq(router.getPrice(POOLTOKEN), 42e18);
        assertEq(router.pairReserveWbnb(POOLTOKEN), 7e18);
        assertTrue(router.isSupported(POOLTOKEN));
        assertEq(uint8(router.status(POOLTOKEN).route), uint8(IPriceOracle.Route.V2));
    }

    function test_Routes_V4Token_ToV4Source() public {
        _warm();
        uint256 expected = V3Twap.spotFromSqrt(Q96, false);
        assertEq(router.getPrice(V4TOKEN), expected);
        assertTrue(router.getPrice(V4TOKEN) != 42e18); // not the pool oracle's price
        assertEq(router.pairReserveWbnb(V4TOKEN), v4.pairReserveWbnb(V4TOKEN));
        assertTrue(router.isSupported(V4TOKEN));
        assertEq(uint8(router.status(V4TOKEN).route), uint8(IPriceOracle.Route.V4));
    }

    function test_Snapshot_ForwardsToV4() public {
        assertEq(v4.snapshotCount(V4TOKEN), 0);
        router.snapshot(V4TOKEN);
        assertEq(v4.snapshotCount(V4TOKEN), 1);
    }

    function test_Snapshot_PoolToken_ForwardsToPool() public {
        router.snapshot(POOLTOKEN);
        assertEq(pool.snapshotCalls(), 1);
        assertEq(pool.lastSnapshot(), POOLTOKEN);
    }

    function test_LiqFloor_FromPool() public view {
        assertEq(router.LIQ_FLOOR(), FLOOR);
    }

    function test_Halt_RouterOwned_OrsIntoStatus() public {
        _warm();
        assertFalse(router.halted(V4TOKEN));
        router.setHalted(V4TOKEN, true);
        assertTrue(router.halted(V4TOKEN));
        assertTrue(router.status(V4TOKEN).halted);
    }

    function test_SetSource_V4_RequiresConfiguredSource() public {
        // a router with no V4 source cannot route to V4
        OracleRouterV4 noV4 =
            new OracleRouterV4(address(pool), address(0), address(0), address(0), address(this));
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        noV4.setSource(V4TOKEN, OracleRouterV4.Source.V4);
    }

    function test_SetSource_OnlyGuardian() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, address(0xBEEF)));
        router.setSource(V4TOKEN, OracleRouterV4.Source.POOL);
    }
}
