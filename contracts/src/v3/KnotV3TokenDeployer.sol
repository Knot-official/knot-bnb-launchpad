// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {KnotV3Token} from "./KnotV3Token.sol";
contract KnotV3TokenDeployer {
    function deploy() external returns (address) { return address(new KnotV3Token(msg.sender)); }
}
