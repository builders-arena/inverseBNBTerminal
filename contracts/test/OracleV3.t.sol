// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract OracleV3Test is Base {
    MockERC20 internal token2;
    MockV3Pool internal pool;

    uint160 internal constant Q96 = uint160(2 ** 96); // tick 0 => price 1.0

    function setUp() public override {
        super.setUp();
        token2 = new MockERC20("Meme2", "MEME2", 18);
        // token2 is token0, WBNB is token1 => tokenIsToken0 = true.
        pool = new MockV3Pool(address(token2), address(wbnb));
        // tick 0, cardinality 64, deep liquidity (depth ~= L*0.00995 >= 50 BNB).
        pool.set(Q96, 0, 64, 1e22);
        v3Factory.setPool(address(token2), address(wbnb), 500, address(pool));
    }

    function test_routesToV3() public view {
        assertEq(uint256(oracle.status(address(token2)).route), uint256(IPriceOracle.Route.V3));
    }

    function test_price_atTickZero_isOne() public view {
        assertEq(oracle.getPrice(address(token2)), 1e18);
    }

    function test_cardinalityTooLow_fallsBack() public {
        pool.set(Q96, 0, 32, 1e22); // below V3_MIN_CARDINALITY -> not a valid V3 route
        // No V2 pair for token2 => unsupported.
        assertFalse(oracle.isSupported(address(token2)));
    }

    function test_warming_whenObserveReverts() public {
        pool.setWarming(true);
        vm.expectRevert(); // OracleWarming
        oracle.getPrice(address(token2));
    }
}
