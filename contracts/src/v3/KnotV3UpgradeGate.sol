// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice The operational wallet proposes upgrades; anyone can execute the exact published upgrade after two days.
/// This contract controls orchestration proxies only. Token supply, LP custody and reward escrow have no proxy.
contract KnotV3UpgradeGate is Ownable2Step {
    uint256 public constant UPGRADE_DELAY = 2 days;
    mapping(bytes32 => uint256) public readyAt;
    event UpgradeScheduled(bytes32 indexed id, address indexed proxy, address indexed implementation,
        address admin, bytes data, uint256 readyAt);
    event UpgradeCancelled(bytes32 indexed id);
    event UpgradeExecuted(bytes32 indexed id);
    constructor(address owner_) Ownable(owner_) {}
    function operation(address admin, address proxy, address implementation, bytes calldata data, bytes32 salt)
        public pure returns (bytes32)
    { return keccak256(abi.encode(admin, proxy, implementation, keccak256(data), salt)); }
    function schedule(address admin, address proxy, address implementation, bytes calldata data, bytes32 salt)
        external onlyOwner returns (bytes32 id)
    {
        require(ProxyAdmin(admin).owner() == address(this) && proxy.code.length > 0
            && implementation.code.length > 0, "UPGRADE_CONFIG");
        id = operation(admin, proxy, implementation, data, salt);
        require(readyAt[id] == 0, "SCHEDULED"); readyAt[id] = block.timestamp + UPGRADE_DELAY;
        emit UpgradeScheduled(id, proxy, implementation, admin, data, readyAt[id]);
    }
    function cancel(bytes32 id) external onlyOwner { delete readyAt[id]; emit UpgradeCancelled(id); }
    function execute(address admin, address proxy, address implementation, bytes calldata data, bytes32 salt) external {
        bytes32 id = operation(admin, proxy, implementation, data, salt);
        require(readyAt[id] > 0 && block.timestamp >= readyAt[id], "UPGRADE_DELAY");
        delete readyAt[id];
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, data);
        emit UpgradeExecuted(id);
    }
}
