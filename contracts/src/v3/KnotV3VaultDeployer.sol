// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {KnotV3FeeVault} from "./KnotV3FeeVault.sol";
contract KnotV3VaultDeployer {
    function deploy(address treasury) external returns (KnotV3FeeVault) {
        return new KnotV3FeeVault(msg.sender, treasury);
    }
}
