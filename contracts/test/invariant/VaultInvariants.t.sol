// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "../Base.t.sol";
import {Handler} from "./Handler.sol";

/// @notice Solvency invariants: the vault can always cover reserved payouts, and shares never price to 0.
contract VaultInvariantsTest is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0);
        _fundVault(1000 ether);
        _warmV2();

        handler = new Handler(engine, vault, oracle, pair, token);
        targetContract(address(handler));
    }

    /// @dev The vault's BNB balance must always be at least the sum of reserved max payouts.
    function invariant_solvent() public view {
        assertGe(address(vault).balance, vault.reserved());
    }

    /// @dev Share price stays strictly positive while shares exist (no division-by-zero / wipeout).
    function invariant_sharePricePositive() public view {
        if (vault.totalShares() > 0) {
            assertGt(vault.sharePrice(), 0);
        }
    }
}
