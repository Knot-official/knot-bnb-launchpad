import {
  createPublicClient,
  createWalletClient,
  custom,
  getAddress,
  http,
  type EIP1193Provider,
} from 'viem';
import { BNB_CHAIN_HEX, BNB_MAINNET, PUBLIC_BNB_RPC } from './network';

export type BrowserProvider = {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
};

export async function ensureBnbMainnet(provider: BrowserProvider) {
  try {
    await provider.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: BNB_CHAIN_HEX }],
    });
  } catch (error) {
    if ((error as { code?: number }).code !== 4902) throw error;
    await provider.request({
      method: 'wallet_addEthereumChain',
      params: [
        {
          chainId: BNB_CHAIN_HEX,
          chainName: BNB_MAINNET.name,
          nativeCurrency: BNB_MAINNET.nativeCurrency,
          rpcUrls: [...BNB_MAINNET.rpcUrls.default.http],
          blockExplorerUrls: [BNB_MAINNET.blockExplorers.default.url],
        },
      ],
    });
  }
}

export async function connectBrowserWallet(
  provider: BrowserProvider,
  rpcUrl: string = PUBLIC_BNB_RPC,
) {
  await ensureBnbMainnet(provider);
  const accounts = await provider.request({ method: 'eth_requestAccounts' });
  if (!Array.isArray(accounts) || typeof accounts[0] !== 'string')
    throw new Error('The wallet did not return an account.');

  const account = getAddress(accounts[0]);
  const publicClient = createPublicClient({
    chain: BNB_MAINNET,
    transport: http(rpcUrl),
  });
  const walletClient = createWalletClient({
    account,
    chain: BNB_MAINNET,
    transport: custom(provider as EIP1193Provider),
  });
  return { account, publicClient, walletClient };
}

