// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {console, Script} from "forge-std/Script.sol";
import {VRFFeeManager} from "../contracts/VRF/VRFFeeManager.sol";

contract DeployVRFFeeManager is Script {
    function run() public returns (VRFFeeManager manager) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        VRFFeeManager.BillingConfig memory billingConfig = VRFFeeManager.BillingConfig({
            coordinatorGasOverhead: uint32(vm.envUint("VRF_COORDINATOR_GAS_OVERHEAD")),
            coordinatorGasOverheadPerWord: uint16(vm.envUint("VRF_COORDINATOR_GAS_OVERHEAD_PER_WORD")),
            gasAfterPaymentCalculation: uint32(vm.envUint("VRF_GAS_AFTER_PAYMENT_CALCULATION")),
            fulfillmentFlatFeeNativePPM: uint32(vm.envUint("VRF_FLAT_FEE_NATIVE_PPM")),
            nativePremiumBps: uint16(vm.envUint("VRF_NATIVE_PREMIUM_BPS"))
        });

        vm.startBroadcast(deployerPrivateKey);
        manager = new VRFFeeManager(
            vm.envAddress("NATIVE_USD_FEED_ADDRESS"),
            uint48(vm.envUint("PRICE_FEED_MAX_AGE")),
            billingConfig
        );
        vm.stopBroadcast();

        console.log("VRFFeeManager deployed to:", address(manager));
    }
}
