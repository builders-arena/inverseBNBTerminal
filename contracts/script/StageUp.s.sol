// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {InverseVault} from "../src/core/InverseVault.sol";
import {InverseEngine} from "../src/core/InverseEngine.sol";

/// @notice Applies a staged-launch parameter set. In production these calls are executed by the
///         Guardian Safe; this script documents the exact parameters per stage (see plan §9).
///
/// Env: VAULT, ENGINE (addresses), STAGE (0..3).
contract StageUp is Script {
    function run() external {
        InverseVault vault = InverseVault(payable(vm.envAddress("VAULT")));
        InverseEngine engine = InverseEngine(payable(vm.envAddress("ENGINE")));
        uint256 stage = vm.envUint("STAGE");

        vm.startBroadcast();
        if (stage == 0) {
            vault.setPoolCap(200 ether);
            engine.setMaxPosition(0.5 ether);
            engine.setMaxLeverageEnabled(2);
            engine.setPayoutCapBps(300);
        } else if (stage == 1) {
            vault.setPoolCap(500 ether);
            engine.setMaxPosition(2 ether);
            engine.setMaxLeverageEnabled(5);
            engine.setPayoutCapBps(200);
        } else if (stage == 2) {
            vault.setPoolCap(2000 ether);
            engine.setMaxPosition(5 ether);
            engine.setMaxLeverageEnabled(10);
            engine.setPayoutCapBps(150);
        } else if (stage == 3) {
            vault.setPoolCap(0); // uncapped
            engine.setMaxPosition(10 ether);
            engine.setMaxLeverageEnabled(10);
            engine.setPayoutCapBps(100);
        } else {
            revert("bad stage");
        }
        vm.stopBroadcast();
        console2.log("Applied stage", stage);
    }
}
