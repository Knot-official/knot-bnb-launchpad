# Knot on BNB Chain

Knot is a token launchpad deployed on **BNB Smart Chain mainnet**. New launches use a continuous PancakeSwap V3 market: a token and its permanently locked, token-only liquidity position are created atomically, and trading begins on BNB Chain without a separate migration transaction.

- Live application: [knot.fun](https://knot.fun)
- Network: BNB Smart Chain mainnet
- Chain ID: `56`
- Native currency: BNB
- Explorer: [BscScan](https://bscscan.com)
- Public RPC used by the example: `https://bsc-dataseed.bnbchain.org`

This repository is the public BNB Chain integration snapshot for Knot. It contains genuine deployed contract source, public ABIs and addresses, and a small browser-wallet/Viem client. Production databases, APIs, indexing services, admin tools, signing infrastructure and operational configuration are intentionally not included.

## BNB Chain deployment

The deployment begins at BNB Smart Chain block `121860961`.

| Contract | BNB mainnet address |
| --- | --- |
| Knot V3 factory proxy | [`0x983b57695152e856c17c39a29d62c4424008c25f`](https://bscscan.com/address/0x983b57695152e856c17c39a29d62c4424008c25f#code) |
| Factory implementation | [`0x44C0925419F70061beb7fdfecbBf42AC084cA00d`](https://bscscan.com/address/0x44C0925419F70061beb7fdfecbBf42AC084cA00d#code) |
| Quote registry | [`0x43640aA1e66BC949fE3d4D7feB00bC6760b83440`](https://bscscan.com/address/0x43640aA1e66BC949fE3d4D7feB00bC6760b83440#code) |
| Fee vault | [`0x75225f3e112e25259a883e2A865433de40F124AF`](https://bscscan.com/address/0x75225f3e112e25259a883e2A865433de40F124AF#code) |
| Liquidity locker | [`0xF420854CeFf1eb259be2FF11cE2aa9376aB9a4ac`](https://bscscan.com/address/0xF420854CeFf1eb259be2FF11cE2aa9376aB9a4ac#code) |
| Token implementation | [`0xAd79a4Ce83662F631f7DF232F6351b86894D9066`](https://bscscan.com/address/0xAd79a4Ce83662F631f7DF232F6351b86894D9066#code) |
| Upgrade gate | [`0x2c10abd8da83806f2062fd57e68aeea54941a2bf`](https://bscscan.com/address/0x2c10abd8da83806f2062fd57e68aeea54941a2bf#code) |

The machine-readable deployment is in [`deployments/bnb-mainnet-v3.json`](deployments/bnb-mainnet-v3.json). BNB network configuration is in [`bnbconfig.json`](bnbconfig.json).

## How Knot uses BNB Chain

1. A user connects an EIP-1193 wallet and switches to BNB Smart Chain, chain ID 56.
2. The user calls `KnotV3Factory.launchContinuous` through the deployed factory proxy.
3. The factory creates a fixed-supply token and a canonical PancakeSwap V3 pool.
4. The complete token supply is placed into a one-sided liquidity position held by `KnotV3Liquidity`.
5. Trading occurs through standard PancakeSwap V3 infrastructure. The original position cannot be transferred or have principal withdrawn through the Knot locker.
6. Fees belonging to the original position are accounted for by `KnotV3FeeVault` according to the launch's reward allocation.

See [architecture](docs/ARCHITECTURE.md), [contract reference](docs/CONTRACTS.md), and [client integration](docs/INTEGRATION.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `contracts/src` | Solidity source for the deployed Continuous V3 contracts and required shared interfaces |
| `abi` | Public JSON ABIs for deployed Knot contracts and proxy contracts |
| `deployments` | Sanitized public BNB mainnet deployment metadata |
| `src` | Standalone BNB network, wallet, deployment and launch helpers |
| `docs` | Public on-chain architecture and integration notes |

## Build and verify

Requirements: Node.js 22+ and npm. Foundry is optional for developers who prefer `forge`.

```bash
npm ci
npm run check

# Optional Foundry build of the same Solidity sources
npm run build:contracts
```

No environment file, private RPC, service token, deployer key or backend is required to build this repository. The included public RPC is suitable for light reads and examples; production integrators should select their own BNB Chain provider.

## Browser-wallet example

```ts
import { connectBrowserWallet, launchContinuous } from './src';

const provider = window.ethereum;
if (!provider) throw new Error('Install an EVM browser wallet');

const { account, publicClient, walletClient } =
  await connectBrowserWallet(provider);

const result = await launchContinuous(publicClient, walletClient, account, {
  name: 'Example',
  symbol: 'EXAMPLE',
  metadataUri: 'https://example.com/token.json',
  quote: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
  dividendBps: 0,
  buybackBps: 0,
});

console.log(result.hash);
```

The helper checks chain ID, connected account, launch pause state and quote-registry approval; simulates writes; uses exact ERC-20 approvals; enforces a five-minute deadline; and waits for successful receipts. It never requests a private key or uses a Knot backend.

## Security and scope

Contract source and deployment addresses are published for transparency and integration. This repository is not a claim of an independent audit. Review the contracts and current on-chain state before sending transactions. Never place private keys, seed phrases, authenticated RPC URLs or service credentials in browser code or repository files.

## License

MIT. See [LICENSE](LICENSE).
