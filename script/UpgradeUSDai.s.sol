// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.29;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {USDai} from "src/USDai.sol";
import {Deployer} from "./utils/Deployer.s.sol";

contract UpgradeUSDai is Deployer {
    function run() public broadcast useDeployment returns (address) {
        if (_deployment.swapAdapter == address(0)) revert MissingDependency();
        if (_deployment.stakedUSDai == address(0)) revert MissingDependency();
        if (_deployment.swapFacility == address(0)) revert MissingDependency();

        // Deploy USDai implementation
        // TODO(R1): If routing option R1 is selected, USDai's constructor will likely
        // drop the `swapAdapter` argument. Update this call to match.
        USDai USDaiImpl = new USDai(
            _deployment.swapAdapter,
            _deployment.stakedUSDai, // baseYieldRecipient_
            _deployment.swapFacility // swapFacility_
        );
        console.log("USDai implementation", address(USDaiImpl));

        /* Build initializer calldata for the v1.5 PYUSD -> MultiMint migration */
        bytes memory initCalldata = abi.encodeCall(USDai.initializeV1_5, ());

        /* Lookup proxy admin */
        address proxyAdmin = address(uint160(uint256(vm.load(_deployment.USDai, ERC1967Utils.ADMIN_SLOT))));

        if (Ownable(proxyAdmin).owner() == msg.sender) {
            /* Upgrade Proxy */
            ProxyAdmin(proxyAdmin).upgradeAndCall(
                ITransparentUpgradeableProxy(_deployment.USDai), address(USDaiImpl), initCalldata
            );
            console.log("Upgraded proxy %s implementation to: %s\n", _deployment.USDai, address(USDaiImpl));
        } else {
            console.log("\nUpgrade calldata");
            console.log("Target:   %s", proxyAdmin);
            console.log("Calldata:");
            console.logBytes(
                abi.encodeWithSelector(
                    ProxyAdmin.upgradeAndCall.selector,
                    ITransparentUpgradeableProxy(_deployment.USDai),
                    address(USDaiImpl),
                    initCalldata
                )
            );
        }

        return address(USDaiImpl);
    }
}
