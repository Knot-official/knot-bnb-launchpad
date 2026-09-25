# Client integration

Knot transactions run directly on BNB Smart Chain mainnet. Integrators need a BNB RPC, an EIP-1193 wallet provider and `viem`; no Knot API key is required for on-chain execution.

## Connect and switch networks

`connectBrowserWallet` requests chain ID 56, adds BNB Smart Chain when necessary, obtains the user's account, and creates Viem public and wallet clients.

```ts
const { account, publicClient, walletClient } =
  await connectBrowserWallet(window.ethereum);
```

The default RPC is public. Pass a different unauthenticated or application-managed RPC URL as the second argument when needed. Never embed provider credentials in browser bundles.

## Launch a continuous market

Call `launchContinuous` with a caller-hosted metadata URI and an enabled quote token. The reward weights are basis points; their sum may not exceed 10,000. Any remainder of the creator share is creator cash.

For a WBNB quote, an optional creator purchase is funded with native BNB in the launch transaction. For any other quote token, the helper performs an exact ERC-20 approval to the factory. The helper first simulates the purchase and applies the selected slippage tolerance to its output.

`launchContinuous` returns the transaction hash, receipt and simulated contract result. The result tuple contains the token address, pool address, position ID and creator purchase output.

## Safe transaction rules

- Require BNB Smart Chain chain ID 56 from both public and wallet clients.
- Recheck the active wallet account immediately before execution.
- Read `QuoteRegistry.quotes(quote)` and reject disabled assets.
- Read the factory's current launch fee and pause state instead of hardcoding execution assumptions.
- Simulate each write before requesting a wallet signature.
- Use integer token units, a nonzero minimum output and a short deadline.
- Treat the factory proxy as the launch target; never launch through the implementation address.
- Host token metadata independently. This public client does not call a private upload or metadata service.
