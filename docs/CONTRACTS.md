# Contract reference

All addresses below are on BNB Smart Chain mainnet, chain ID 56.

| Contract | Address | Purpose |
| --- | --- | --- |
| `KnotV3Factory` proxy | `0x983b57695152e856c17c39a29d62c4424008c25f` | Public launch entry point |
| `KnotV3Factory` implementation | `0x44C0925419F70061beb7fdfecbBf42AC084cA00d` | Current factory logic; not a launch target |
| `QuoteRegistry` | `0x43640aA1e66BC949fE3d4D7feB00bC6760b83440` | Approved quote assets and starting reserves |
| `KnotV3FeeVault` | `0x75225f3e112e25259a883e2A865433de40F124AF` | Fee accounting, claims, dividends and buyback allocation |
| `KnotV3Liquidity` | `0xF420854CeFf1eb259be2FF11cE2aa9376aB9a4ac` | Permanent custody of original PancakeSwap V3 positions |
| `KnotV3Token` implementation | `0xAd79a4Ce83662F631f7DF232F6351b86894D9066` | Implementation used by launched token clones |
| `KnotV3UpgradeGate` | `0x2c10abd8da83806f2062fd57e68aeea54941a2bf` | Delayed factory-upgrade control |
| `ProxyAdmin` | `0x5ee0441B3546137F4F52D859fA94cF7a01ecCFd2` | OpenZeppelin proxy administrator owned by the upgrade gate |

## BNB/PancakeSwap dependencies

| Contract | Address |
| --- | --- |
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| PancakeSwap V3 router | `0x1b81D678ffb9C0263b24A97847620C99d213eB14` |
| PancakeSwap V3 quoter | `0xB048Bbc1Ee6B733FFfCFb9e9CeF7375518e25997` |
| PancakeSwap V3 position manager | `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364` |

The canonical data file is [`../deployments/bnb-mainnet-v3.json`](../deployments/bnb-mainnet-v3.json). ABIs are available in [`../abi`](../abi).

