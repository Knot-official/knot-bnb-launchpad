import {
  erc20Abi,
  getAddress,
  parseAbi,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from 'viem';
import factoryJson from '../abi/KnotV3Factory.json';
import { KNOT_DEPLOYMENT } from './contracts';
import { BNB_MAINNET } from './network';

const factoryAbi = factoryJson as Abi;
const registryAbi = parseAbi([
  'function quotes(address) view returns(bool enabled,uint8 decimals,uint8 kind,uint128 virtualReserve)',
]);

export type ContinuousLaunch = {
  name: string;
  symbol: string;
  metadataUri: string;
  quote: Address;
  dividendBps: number;
  buybackBps: number;
  creatorInput?: bigint;
  slippageBps?: number;
  salt?: Hex;
};

export function randomSalt(): Hex {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return `0x${Array.from(bytes, (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('')}`;
}

function validate(input: ContinuousLaunch) {
  const size = (value: string) => new TextEncoder().encode(value).length;
  if (!size(input.name) || size(input.name) > 64)
    throw new Error('Name must contain 1–64 UTF-8 bytes.');
  if (!size(input.symbol) || size(input.symbol) > 12)
    throw new Error('Symbol must contain 1–12 UTF-8 bytes.');
  if (size(input.metadataUri) > 2048)
    throw new Error('Metadata URI is too long.');
  if (
    !Number.isInteger(input.dividendBps) ||
    !Number.isInteger(input.buybackBps) ||
    input.dividendBps < 0 ||
    input.buybackBps < 0 ||
    input.dividendBps + input.buybackBps > 10_000
  )
    throw new Error('Reward allocation must total at most 10,000 bps.');
  const slippage = input.slippageBps ?? 100;
  if (!Number.isInteger(slippage) || slippage < 1 || slippage > 500)
    throw new Error('Slippage must be between 1 and 500 bps.');
}

async function approveExact(
  publicClient: PublicClient,
  walletClient: WalletClient,
  account: Address,
  asset: Address,
  amount: bigint,
) {
  const current = await publicClient.readContract({
    address: asset,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [account, KNOT_DEPLOYMENT.factory],
  });
  if (current === amount) return;
  for (const value of current > 0n ? [0n, amount] : [amount]) {
    const { request } = await publicClient.simulateContract({
      account,
      address: asset,
      abi: erc20Abi,
      functionName: 'approve',
      args: [KNOT_DEPLOYMENT.factory, value],
    });
    const hash = await walletClient.writeContract({
      ...request,
      account,
      chain: BNB_MAINNET,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error('Approval reverted.');
  }
}

export async function launchContinuous(
  publicClient: PublicClient,
  walletClient: WalletClient,
  accountInput: Address,
  input: ContinuousLaunch,
) {
  validate(input);
  const account = getAddress(accountInput);
  const quote = getAddress(input.quote);
  const creatorInput = input.creatorInput ?? 0n;
  if (creatorInput < 0n) throw new Error('Creator input cannot be negative.');

  const [publicChain, walletChain, walletAccounts, paused, launchFee, quoteData] =
    await Promise.all([
      publicClient.getChainId(),
      walletClient.getChainId(),
      walletClient.getAddresses(),
      publicClient.readContract({
        address: KNOT_DEPLOYMENT.factory,
        abi: factoryAbi,
        functionName: 'launchesPaused',
      }),
      publicClient.readContract({
        address: KNOT_DEPLOYMENT.factory,
        abi: factoryAbi,
        functionName: 'launchFee',
      }),
      publicClient.readContract({
        address: KNOT_DEPLOYMENT.quoteRegistry,
        abi: registryAbi,
        functionName: 'quotes',
        args: [quote],
      }),
    ]);
  if (publicChain !== 56 || walletChain !== 56)
    throw new Error('Switch both clients to BNB Smart Chain mainnet.');
  if (!walletAccounts.some((value) => value.toLowerCase() === account.toLowerCase()))
    throw new Error('The connected wallet account changed.');
  if (paused !== false) throw new Error('Continuous launches are paused.');
  if (!quoteData[0]) throw new Error('The selected quote asset is not enabled.');

  const nativeQuote = quote.toLowerCase() === KNOT_DEPLOYMENT.wrappedBNB.toLowerCase();
  if (creatorInput > 0n && !nativeQuote)
    await approveExact(publicClient, walletClient, account, quote, creatorInput);

  const salt = input.salt ?? randomSalt();
  const deadline = (await publicClient.getBlock()).timestamp + 300n;
  const value = (launchFee as bigint) + (nativeQuote ? creatorInput : 0n);
  const baseArgs = [
    input.name,
    input.symbol,
    input.metadataUri,
    quote,
    salt,
    { dividendBps: input.dividendBps, buybackBps: input.buybackBps },
    creatorInput,
  ] as const;

  let minimum = 0n;
  if (creatorInput > 0n) {
    const preview = await publicClient.simulateContract({
      account,
      address: KNOT_DEPLOYMENT.factory,
      abi: factoryAbi,
      functionName: 'launchContinuous',
      args: [...baseArgs, 1n, deadline],
      value,
    });
    const output = (preview.result as readonly [Address, Address, bigint, bigint])[3];
    minimum =
      (output * BigInt(10_000 - (input.slippageBps ?? 100))) / 10_000n;
    if (minimum <= 0n) throw new Error('Creator purchase output is too small.');
  }

  const simulation = await publicClient.simulateContract({
    account,
    address: KNOT_DEPLOYMENT.factory,
    abi: factoryAbi,
    functionName: 'launchContinuous',
    args: [...baseArgs, minimum, deadline],
    value,
  });
  const hash = await walletClient.writeContract({
    ...simulation.request,
    account,
    chain: BNB_MAINNET,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error('Launch transaction reverted.');
  return { hash, receipt, simulatedResult: simulation.result };
}
