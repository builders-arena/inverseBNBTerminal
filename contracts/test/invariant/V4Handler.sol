// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {V4Source} from "../../src/oracle/V4Source.sol";
import {V3Twap} from "../../src/oracle/V3Twap.sol";
import {MockStateView} from "../mocks/MockStateView.sol";

/// @notice Drives a V4Source with time warps and bounded spot moves, writing samples via snapshot().
///         Tracks the extremes of every spot it has ever set so the invariant can check that any
///         successful TWAP lies within them (a time-weighted average can never leave the sample band).
contract V4Handler is Test {
    uint160 internal constant Q96 = 79228162514264337593543950336;

    V4Source public immutable v4;
    MockStateView public immutable sv;
    address public immutable token;
    bytes32 public immutable poolId;

    uint256 public minSpot;
    uint256 public maxSpot;
    bool public token0;

    constructor(V4Source v4_, MockStateView sv_, address token_, bytes32 poolId_, bool token0_, uint256 initSpot) {
        v4 = v4_;
        sv = sv_;
        token = token_;
        poolId = poolId_;
        token0 = token0_;
        minSpot = initSpot;
        maxSpot = initSpot;
    }

    /// Advance time by [1s, 10min], move the spot within a modest band, and take a snapshot.
    function warpAndSnap(uint256 timeSeed, uint256 priceSeed) external {
        uint256 dt = bound(timeSeed, 1, 600);
        vm.warp(block.timestamp + dt);

        // spot = mult^2 * 1e18, mult in [8,12] => spot in {64e18 .. 144e18}: wide enough to exercise
        // the deviation breaker, tight enough that getPrice often succeeds.
        uint256 mult = bound(priceSeed, 8, 12);
        sv.setSqrtPrice(poolId, uint160(uint256(Q96) * mult));
        uint256 spot = V3Twap.spotFromSqrt(uint160(uint256(Q96) * mult), token0);

        v4.snapshot(token);

        if (spot < minSpot) minSpot = spot;
        if (spot > maxSpot) maxSpot = spot;
    }
}
