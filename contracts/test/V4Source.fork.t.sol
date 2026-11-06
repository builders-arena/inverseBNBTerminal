// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {V4Source} from "../src/oracle/V4Source.sol";
import {V4PoolId} from "../src/libraries/V4PoolId.sol";
import {V3Twap} from "../src/oracle/V3Twap.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @notice Forked Robinhood-Chain (chain 4663) test against the LIVE Uniswap V4 StateView + the real
///         ROBINHOOD/ETH pool. Validates the poolId math, the StateView→PoolManager wiring, and that
///         V4Source reads a sane spot/depth and warms + prices end-to-end off real on-chain state.
///
///         Runs only when ROBINHOOD_FORK_RPC is set (otherwise each test vm.skip()s), so `forge test`
///         stays green offline/CI. Run it with:
///           ROBINHOOD_FORK_RPC=https://rpc.mainnet.chain.robinhood.com \
///             forge test --match-contract V4SourceFork -vvv
contract V4SourceForkTest is Test {
    // Verified live V4 singletons on chain 4663.
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    // ROBINHOOD token + settlement WETH.
    address internal constant ROBINHOOD = 0x008Df4b3E857D06c4603Aeb11F267ccD32ce2005;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant HOOKS = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    bytes32 internal constant POOL_ID = 0x7f8271c1a7a6a434f33b0babc15bf2980a0dcb4196848b4f7e789a7fd73a5350;

    bool internal forked;
    V4Source internal v4;
    V4PoolId.PoolKey internal key;

    function setUp() public {
        key = V4PoolId.PoolKey({
            currency0: address(0), // native ETH
            currency1: ROBINHOOD,
            fee: 0,
            tickSpacing: 200,
            hooks: HOOKS
        });

        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return; // not forked -> tests skip
        vm.createSelectFork(rpc);
        forked = true;
        // 0.001 ETH band-depth floor (well under the ~0.23 ETH band depth observed in the spike).
        v4 = new V4Source(WETH, STATE_VIEW, 1e15, 20 minutes, address(this));
    }

    /// poolId math holds regardless of fork (pure).
    function test_PoolIdMatchesLivePool() public pure {
        assertEq(V4PoolId.toId(_key()), POOL_ID);
    }

    function test_StateViewWiring() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        assertEq(IStateView(STATE_VIEW).poolManager(), POOL_MANAGER);
        (uint160 sqrtP,,,) = IStateView(STATE_VIEW).getSlot0(POOL_ID);
        assertGt(sqrtP, 0);
        assertGt(IStateView(STATE_VIEW).getLiquidity(POOL_ID), 0);
    }

    function test_RegisterAndReadLivePool() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        v4.register(ROBINHOOD, key);
        (bool registered, bytes32 id, bool token0,) = v4.poolOf(ROBINHOOD);
        assertTrue(registered);
        assertEq(id, POOL_ID);
        assertFalse(token0); // ETH is currency0, ROBINHOOD is currency1

        IPriceOracle.Status memory s = v4.status(ROBINHOOD);
        assertEq(uint8(s.route), uint8(IPriceOracle.Route.V4));
        assertTrue(s.supported);
        assertGt(s.spot, 0);
        assertGt(s.reserveBnb, 0);
        // ROBINHOOD ~ 6.5e-7 ETH at spike time; allow a wide band for price drift (1e-9 .. 1e-4 ETH).
        assertGt(s.spot, 1e9);
        assertLt(s.spot, 1e14);
        console2.log("ROBINHOOD spot (ETH, 1e18):", s.spot);
        console2.log("band depth (ETH, 1e18):", s.reserveBnb);
    }

    function test_WarmAndPriceLivePool() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        v4.register(ROBINHOOD, key);

        uint256 t = block.timestamp;
        v4.snapshot(ROBINHOOD); // sample A @ t
        vm.warp(t + 6 minutes);
        v4.snapshot(ROBINHOOD); // sample B @ t+360 (anchor A now in [5,30]min)

        uint256 price = v4.getPrice(ROBINHOOD);
        // fork price is frozen, so every sample reads the same spot => twap == spot exactly.
        assertEq(price, v4.status(ROBINHOOD).spot);
        assertGt(price, 0);
    }

    function _key() internal pure returns (V4PoolId.PoolKey memory k) {
        k = V4PoolId.PoolKey({
            currency0: address(0),
            currency1: ROBINHOOD,
            fee: 0,
            tickSpacing: 200,
            hooks: HOOKS
        });
    }
}
