// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {KnotV3Liquidity} from "./KnotV3Liquidity.sol";
import {KnotV3FeeVault} from "./KnotV3FeeVault.sol";
contract KnotV3LiquidityDeployer {
    function deploy(address manager, KnotV3FeeVault vault) external returns (KnotV3Liquidity) {
        return new KnotV3Liquidity(msg.sender, manager, vault);
    }
}
