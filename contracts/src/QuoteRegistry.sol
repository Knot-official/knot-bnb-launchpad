// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice The owner manages quote approvals, which affect new launches only.
contract QuoteRegistry is Ownable2Step {
    struct Quote {
        bool enabled;
        uint8 decimals;
        uint8 kind;
        uint128 virtualReserve;
    }
    mapping(address => Quote) public quotes;
    event QuoteConfigured(address indexed asset, bool enabled, uint8 decimals, uint8 kind, uint128 virtualReserve);

    constructor(address owner_) Ownable(owner_) {}

    function configure(address asset, bool enabled, uint8 kind, uint128 virtualReserve) external onlyOwner {
        // Revocation must work even if an issuer upgrade breaks metadata reads or removes code.
        if (!enabled) {
            Quote storage existing = quotes[asset];
            require(existing.virtualReserve != 0, "UNKNOWN_ASSET");
            existing.enabled = false;
            emit QuoteConfigured(asset, false, existing.decimals, existing.kind, existing.virtualReserve);
            return;
        }
        require(asset.code.length > 0 && kind <= 3, "ASSET");
        uint8 decimals = IERC20Metadata(asset).decimals();
        require(decimals <= 18 && virtualReserve >= 1000 && virtualReserve <= 1e30, "RANGE");
        quotes[asset] = Quote(enabled, decimals, kind, virtualReserve);
        emit QuoteConfigured(asset, enabled, decimals, kind, virtualReserve);
    }

    function approved(address asset) external view returns (Quote memory config) {
        config = quotes[asset];
        require(config.enabled, "QUOTE_DISABLED");
    }
}
