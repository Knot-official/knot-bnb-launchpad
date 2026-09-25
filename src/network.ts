import { defineChain } from 'viem';

export const BNB_MAINNET = defineChain({
  id: 56,
  name: 'BNB Smart Chain',
  nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
  rpcUrls: {
    default: { http: ['https://bsc-dataseed.bnbchain.org'] },
  },
  blockExplorers: {
    default: { name: 'BscScan', url: 'https://bscscan.com' },
  },
});

export const BNB_CHAIN_HEX = '0x38';
export const PUBLIC_BNB_RPC = BNB_MAINNET.rpcUrls.default.http[0];

