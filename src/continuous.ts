import { parseAbi } from "viem";

export const continuousAbi = parseAbi([
  "function continuousVersion() view returns(uint256)",
  "function launchContinuous(string name,string symbol,string uri,address quote,bytes32 salt,(uint16 dividendBps,uint16 buybackBps) rewards,uint256 creatorInput,uint256 minimum,uint256 deadline) payable returns(address token,address pool,uint256 positionId,uint256 creatorOutput)",
  "event ContinuousPosition(address indexed token,uint256 indexed positionId,uint160 sqrtLowerX96,uint160 sqrtUpperX96,uint128 liquidity,uint256 initialTokens)",
]);
export type ContinuousRange = { lower: bigint; upper: bigint; liquidity: bigint; initialTokens: bigint; token0: boolean };
const Q96 = 1n << 96n;
const ceilDiv = (n: bigint, d: bigint) => (n + d - 1n) / d;
/** Original position principal only. Donations, fees and other LPs never enter the calculation. */
export function continuousProgress(range: ContinuousRange, sqrtPrice: bigint) {
  const { lower, upper, liquidity, initialTokens, token0 } = range;
  if (lower <= 0n || upper <= lower || liquidity <= 0n || initialTokens <= 0n)
    throw new Error("Invalid continuous liquidity range");
  const price = sqrtPrice < lower ? lower : sqrtPrice > upper ? upper : sqrtPrice;
  const remaining = token0
    ? ceilDiv(ceilDiv((liquidity << 96n) * (upper - price), upper), price)
    : ceilDiv(liquidity * (price - lower), Q96);
  const sold = initialTokens > remaining ? initialTokens - remaining : 0n;
  const reserve = token0
    ? liquidity * (price - lower) / Q96
    : ((liquidity << 96n) * (upper - price) / upper) / price;
  return { remaining, sold, reserve, graduated: sold * 10000n >= initialTokens * 8000n };
}

export const continuousVaultAbi = parseAbi(["function quoteSweep(address token,address quote) returns(uint256 converted,uint256 spent,uint256 burned,uint256 revenue)"]);
