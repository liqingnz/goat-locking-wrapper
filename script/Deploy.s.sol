pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ValidatorEntry} from "../src/ValidatorEntry.sol";
import {ValidatorEntryUpgradeable} from "../src/ValidatorEntryUpgradeable.sol";
import {ILocking} from "../src/interfaces/IGoatLocking.sol";

contract Deploy is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        bool deployUpgradeable = vm.envOr("DEPLOY_UPGRADEABLE", true);

        vm.startBroadcast(deployerPrivateKey);
        if (deployUpgradeable) {
            _deployValidatorEntryUpgradeable(deployer);
        } else {
            _deployValidatorEntry(deployer);
        }
        vm.stopBroadcast();
    }

    function _deployValidatorEntry(address deployer) internal {
        address lockingAddr = vm.envAddress("LOCKING_ADDR");
        address rewardTokenAddr = vm.envAddress("REWARD_TOKEN_ADDR");
        address foundationAddr = vm.envAddress("FOUNDATION_ADDR");

        ValidatorEntry validatorEntry = new ValidatorEntry(
            ILocking(lockingAddr),
            IERC20(rewardTokenAddr),
            foundationAddr
        );

        console.log("Locking contract address:", lockingAddr);
        console.log("Reward token address:", rewardTokenAddr);
        console.log("Foundation address:", foundationAddr);

        address ownerAddr = vm.envOr("OWNER_ADDR", address(0));
        if (ownerAddr != address(0) && ownerAddr != deployer) {
            validatorEntry.transferOwnership(ownerAddr);
            console.log("ValidatorEntry owner transferred to:", ownerAddr);
        }

        console.log("ValidatorEntry deployed at:", address(validatorEntry));
        console.log("ValidatorEntry owner:", validatorEntry.owner());
    }

    function _deployValidatorEntryUpgradeable(address deployer) internal {
        address lockingAddr = vm.envAddress("LOCKING_ADDR");
        address rewardTokenAddr = vm.envAddress("REWARD_TOKEN_ADDR");
        address foundationAddr = vm.envAddress("FOUNDATION_ADDR");
        address ownerAddr = vm.envOr("OWNER_ADDR", address(0));

        ValidatorEntryUpgradeable implementation = new ValidatorEntryUpgradeable();

        bytes memory initData = abi.encodeCall(
            ValidatorEntryUpgradeable.initialize,
            (
                ILocking(lockingAddr),
                IERC20(rewardTokenAddr),
                foundationAddr,
                ownerAddr
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        ValidatorEntryUpgradeable validatorEntry = ValidatorEntryUpgradeable(
            payable(address(proxy))
        );

        console.log("Locking contract address:", lockingAddr);
        console.log("Reward token address:", rewardTokenAddr);
        console.log("Foundation address:", foundationAddr);
        console.log(
            "ValidatorEntryUpgradeable implementation:",
            address(implementation)
        );
        console.log(
            "ValidatorEntryUpgradeable proxy:",
            address(validatorEntry)
        );
        console.log("ValidatorEntryUpgradeable owner:", validatorEntry.owner());
    }
}
