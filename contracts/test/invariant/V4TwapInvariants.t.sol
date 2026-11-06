// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {V4Source} from "../../src/oracle/V4Source.sol";
import {V4PoolId} from "../../src/libraries/V4PoolId.sol";
import {V3Twap} from "../../src/oracle/V3Twap.sol";
import {MockStateView} from "../mocks/MockStateView.sol";
import {V4Handler} from "./V4Handler.sol";

/// @notice Invariant: the sampled-spot TWAP can never leave the band of spot prices that have been
///         sampled — a time-weighted average of in-band samples stays in-band. If this held false the
///         TWAP could be pushed past any single observation, defeating the manipulation resistance.
contract V4TwapInvariantsTest is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336;
    address internal constant WETH = address(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    address internal constant TOKEN = address(0x0000000000000000000000000000000000000111); // < WETH => currency0

    V4Source internal v4;
    MockStateView internal sv;
    V4Handler internal handler;
    bytes32 internal id;

    function setUp() public {
        sv = new MockStateView(address(0x9999));
        v4 = new V4Source(WETH, address(sv), 1e15, 20 minutes, address(this));

        V4PoolId.PoolKey memory key = V4PoolId.PoolKey({
            currency0: TOKEN,
            currency1: WETH,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        id = V4PoolId.toId(key);
        uint160 start = uint160(uint256(Q96) * 10); // spot 100e18
        sv.setPool(id, start, 0, uint128(1e24)); // deep, constant liquidity so depth never gates
        v4.register(TOKEN, key);

        handler = new V4Handler(v4, sv, TOKEN, id, true, V3Twap.spotFromSqrt(start, true));
        targetContract(address(handler));
    }

    /// @dev Whenever a price is routable, the TWAP lies within [minSampledSpot, maxSampledSpot].
    function invariant_twapWithinSampledBand() public view {
        try v4.getPrice(TOKEN) returns (uint256 twap) {
            assertGe(twap, handler.minSpot());
            assertLe(twap, handler.maxSpot());
        } catch {
            // warming / stale / deviation / low-liquidity: no price to bound.
        }
    }

    /// @dev The ring never reports more than its capacity; a registered token stays supported.
    function invariant_ringBounded() public view {
        assertLe(v4.snapshotCount(TOKEN), 16);
        assertTrue(v4.isSupported(TOKEN));
    }
}
