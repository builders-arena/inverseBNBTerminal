// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {V4Source} from "../src/oracle/V4Source.sol";
import {V4PoolId} from "../src/libraries/V4PoolId.sol";
import {V3Twap} from "../src/oracle/V3Twap.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {Governed} from "../src/libraries/Governed.sol";
import {MockStateView} from "./mocks/MockStateView.sol";

/// @notice Unit tests for V4Source: PoolKey registry validation, the sampled-spot TWAP ring, the
///         staleness/warming guards, the 25% deviation circuit breaker, the depth floor, and guardian
///         gating — using a controllable MockStateView so prices/liquidity can be set exactly.
contract OracleV4Test is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336; // 2**96 (spot == 1e18 when token0)

    V4Source internal v4;
    MockStateView internal sv;

    address internal constant WETH = address(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    address internal guardian = address(this);
    uint256 internal constant FLOOR = 1e16; // 0.01 ETH band-depth floor for tests

    // ETH-quoted pool (like ROBINHOOD): currency0 = native ETH (0x0), currency1 = token.
    address internal constant TOKEN = address(0x00000000000000000000000000000000DeaDBeef);
    V4PoolId.PoolKey internal ethKey;
    bytes32 internal ethId;

    function setUp() public {
        sv = new MockStateView(address(0x9999));
        v4 = new V4Source(WETH, address(sv), FLOOR, guardian);

        ethKey = V4PoolId.PoolKey({
            currency0: address(0),
            currency1: TOKEN,
            fee: 0,
            tickSpacing: 200,
            hooks: address(0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044)
        });
        ethId = V4PoolId.toId(ethKey);
        // seed a live pool: spot 1.0, deep liquidity
        sv.setPool(ethId, Q96, 0, uint128(1e24));
    }

    // ----- helpers -----
    function _spot(uint160 sqrtP, bool token0) internal pure returns (uint256) {
        return V3Twap.spotFromSqrt(sqrtP, token0);
    }

    function _registerEth() internal {
        v4.register(TOKEN, ethKey);
    }

    /// Build a warm ring at a constant sqrtP: samples at t, t+6min; both equal → twap == spot exactly.
    function _warmStable(uint160 sqrtP) internal {
        sv.setSqrtPrice(ethId, sqrtP);
        v4.snapshot(TOKEN); // sample A
        vm.warp(block.timestamp + 6 minutes);
        v4.snapshot(TOKEN); // sample B (anchor A now 6min old, in [5,30])
    }

    // =========================================================================
    //                          poolId math / registry
    // =========================================================================

    function test_PoolIdMatchesAbiEncode() public pure {
        V4PoolId.PoolKey memory k = V4PoolId.PoolKey({
            currency0: address(0),
            currency1: address(0x008Df4b3E857D06c4603Aeb11F267ccD32ce2005),
            fee: 0,
            tickSpacing: 200,
            hooks: address(0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044)
        });
        // The live ROBINHOOD/ETH poolId, validated on-chain (chain 4663).
        assertEq(V4PoolId.toId(k), 0x7f8271c1a7a6a434f33b0babc15bf2980a0dcb4196848b4f7e789a7fd73a5350);
    }

    function test_Register_Success() public {
        _registerEth();
        (bool registered, bytes32 id, bool token0,) = v4.poolOf(TOKEN);
        assertTrue(registered);
        assertEq(id, ethId);
        assertFalse(token0); // token is currency1
        assertTrue(v4.isSupported(TOKEN));
    }

    function test_Register_RejectsTokenNotInKey() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, address(0x1234)));
        v4.register(address(0x1234), ethKey);
    }

    function test_Register_RejectsNonEthWethQuote() public {
        // a pool of token/otherToken (neither currency is ETH or WETH)
        address other = address(0x00000000000000000000000000000000cafebabe);
        V4PoolId.PoolKey memory bad = V4PoolId.PoolKey({
            currency0: other < TOKEN ? other : TOKEN,
            currency1: other < TOKEN ? TOKEN : other,
            fee: 0,
            tickSpacing: 200,
            hooks: address(0)
        });
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, TOKEN));
        v4.register(TOKEN, bad);
    }

    function test_Register_RejectsBadOrdering() public {
        // currency0 >= currency1 violates the V4 sort invariant
        V4PoolId.PoolKey memory bad = V4PoolId.PoolKey({
            currency0: TOKEN,
            currency1: address(0), // ETH must be currency0, so this is mis-sorted
            fee: 0,
            tickSpacing: 200,
            hooks: address(0)
        });
        vm.expectRevert(abi.encodeWithSelector(Errors.OutOfBounds.selector, 0, 0, 0));
        v4.register(TOKEN, bad);
    }

    function test_Register_RejectsUninitializedPool() public {
        sv.setPool(ethId, 0, 0, 0); // sqrtP 0 => not initialized
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, TOKEN));
        _registerEth();
    }

    function test_Register_RejectsZeroLiquidity() public {
        sv.setPool(ethId, Q96, 0, 0); // initialized but no liquidity
        vm.expectRevert(abi.encodeWithSelector(Errors.LowLiquidity.selector, TOKEN, 0));
        _registerEth();
    }

    function test_Register_OnlyGuardian() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, address(0xBEEF)));
        _registerEth();
    }

    function test_Deregister() public {
        _registerEth();
        v4.deregister(TOKEN);
        assertFalse(v4.isSupported(TOKEN));
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, TOKEN));
        v4.getPrice(TOKEN);
    }

    // =========================================================================
    //                          warming / staleness / price
    // =========================================================================

    function test_Warming_NoSamples() public {
        _registerEth();
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleWarming.selector, TOKEN, block.timestamp + 5 minutes));
        v4.getPrice(TOKEN);
    }

    function test_Warming_UntilAnchorInWindow() public {
        _registerEth();
        v4.snapshot(TOKEN); // one sample at t0
        // still warming: no sample is >= WINDOW_MIN (5 min) old yet
        vm.warp(block.timestamp + 2 minutes);
        v4.snapshot(TOKEN);
        vm.expectRevert(); // OracleWarming (no anchor in [5,30] min)
        v4.getPrice(TOKEN);
    }

    function test_Price_AfterWarm_StableEqualsSpot() public {
        _registerEth();
        _warmStable(Q96);
        uint256 expected = _spot(Q96, false); // 1e18
        assertEq(v4.getPrice(TOKEN), expected);
    }

    function test_Stale_NewestTooOld() public {
        _registerEth();
        _warmStable(Q96);
        vm.warp(block.timestamp + 6 minutes); // newest sample now 6min > MAX_SNAPSHOT_AGE (5min)
        vm.expectRevert(abi.encodeWithSelector(Errors.Stale.selector, TOKEN, 6 minutes));
        v4.getPrice(TOKEN);
    }

    function test_DepthFloor_LowLiquidityReverts() public {
        _registerEth();
        _warmStable(Q96);
        // drop liquidity so band depth < FLOOR
        sv.setLiquidity(ethId, uint128(1e6));
        uint256 depth = V3Twap.wbnbDepth(1e6, Q96, false);
        assertLt(depth, FLOOR);
        vm.expectRevert(abi.encodeWithSelector(Errors.LowLiquidity.selector, TOKEN, depth));
        v4.getPrice(TOKEN);
    }

    function test_SampleMinGap_NoDoubleWrite() public {
        _registerEth();
        v4.snapshot(TOKEN);
        assertEq(v4.snapshotCount(TOKEN), 1);
        v4.snapshot(TOKEN); // same block → within gap, no write
        assertEq(v4.snapshotCount(TOKEN), 1);
        vm.warp(block.timestamp + 61);
        v4.snapshot(TOKEN);
        assertEq(v4.snapshotCount(TOKEN), 2);
    }

    // =========================================================================
    //                          deviation circuit breaker
    // =========================================================================

    function test_Deviation_WithinBandPasses() public {
        _registerEth();
        _warmStable(Q96); // twap == spot(Q96)
        // move spot ~ -17% (sqrtP * 1.1 for a token1-quoted pool) — under 25%
        uint160 moved = uint160(uint256(Q96) * 110 / 100);
        sv.setSqrtPrice(ethId, moved);
        uint256 spot = _spot(moved, false);
        uint256 twap = _spot(Q96, false);
        uint256 dev = (_absDiff(spot, twap) * 10_000) / twap;
        assertLt(dev, 2500);
        // returns the twap (unchanged by the spot move, since samples still read Q96 via stored prices)
        assertEq(v4.getPrice(TOKEN), twap);
    }

    function test_Deviation_BeyondBandReverts() public {
        _registerEth();
        _warmStable(Q96);
        uint160 moved = uint160(uint256(Q96) * 120 / 100); // spot ~ -30%
        sv.setSqrtPrice(ethId, moved);
        uint256 spot = _spot(moved, false);
        uint256 twap = _spot(Q96, false);
        assertGt((_absDiff(spot, twap) * 10_000) / twap, 2500);
        vm.expectRevert(abi.encodeWithSelector(Errors.Deviation.selector, TOKEN, spot, twap));
        v4.getPrice(TOKEN);
    }

    // =========================================================================
    //                          time-weighting (exact)
    // =========================================================================

    /// WETH-quoted pool with token as currency0 so spot == (sqrtP/2^96)^2 * 1e18 exactly; pick
    /// perfect-square multipliers so sample prices are exact and the TWAP is checkable to the wei.
    function test_Twap_TimeWeightedAverage() public {
        address tok = address(0x0000000000000000000000000000000000000111); // < WETH => currency0
        V4PoolId.PoolKey memory k = V4PoolId.PoolKey({
            currency0: tok,
            currency1: WETH,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        bytes32 id = V4PoolId.toId(k);
        uint160 s10 = uint160(uint256(Q96) * 10); // spot 100e18
        sv.setPool(id, s10, 0, uint128(1e24));
        v4.register(tok, k);

        vm.warp(100_000);
        v4.snapshot(tok); // A {100000, 100e18, cum 0}
        vm.warp(100_600);
        sv.setSqrtPrice(id, uint160(uint256(Q96) * 11)); // spot 121e18
        v4.snapshot(tok); // B {100600, 121e18, cum = 100e18*600}
        vm.warp(101_200);
        v4.snapshot(tok); // C {101200, 121e18, cum = 100e18*600 + 121e18*600}
        assertEq(v4.snapshotCount(tok), 3);

        // anchor = oldest in [5,30]min = A (20min old). newest C age 0 => cumNow = C.cum.
        // twap = (100e18*600 + 121e18*600) / 1200 = (100e18+121e18)/2 = 110.5e18
        assertEq(_spot(s10, true), 100e18);
        assertEq(v4.getPrice(tok), 1105e17); // 110.5e18
    }

    // =========================================================================
    //                          halt / guardian / route-override
    // =========================================================================

    function test_Halt_SetByGuardian() public {
        _registerEth();
        assertFalse(v4.halted(TOKEN));
        v4.setHalted(TOKEN, true);
        assertTrue(v4.halted(TOKEN));
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Errors.NotGuardian.selector, address(0xBEEF)));
        v4.setHalted(TOKEN, false);
    }

    function test_SetRouteOverride_RevertsUnsupported() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.Unsupported.selector, TOKEN));
        v4.setRouteOverride(TOKEN, IPriceOracle.Route.V4);
    }

    function test_Status_ReportsV4Route() public {
        _registerEth();
        _warmStable(Q96);
        IPriceOracle.Status memory s = v4.status(TOKEN);
        assertEq(uint8(s.route), uint8(IPriceOracle.Route.V4));
        assertTrue(s.supported);
        assertFalse(s.warming);
        assertEq(s.twap, _spot(Q96, false));
        assertGt(s.reserveBnb, 0);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
