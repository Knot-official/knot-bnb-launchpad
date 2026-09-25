import { getAddress } from 'viem';
import deployment from '../deployments/bnb-mainnet-v3.json';

export const KNOT_DEPLOYMENT = {
  chainId: deployment.chainId,
  startBlock: BigInt(deployment.startBlock),
  launchFeeBNB: deployment.launchFeeBNB,
  factory: getAddress(deployment.contracts.factoryProxy),
  factoryImplementation: getAddress(
    deployment.contracts.factoryImplementation,
  ),
  proxyAdmin: getAddress(deployment.contracts.proxyAdmin),
  upgradeGate: getAddress(deployment.contracts.upgradeGate),
  feeVault: getAddress(deployment.contracts.feeVault),
  liquidityLocker: getAddress(deployment.contracts.liquidityLocker),
  quoteRegistry: getAddress(deployment.contracts.quoteRegistry),
  tokenImplementation: getAddress(deployment.contracts.tokenImplementation),
  wrappedBNB: getAddress(deployment.bnbInfrastructure.wrappedBNB),
  pancakeV3Router: getAddress(
    deployment.bnbInfrastructure.pancakeV3Router,
  ),
  pancakeV3Quoter: getAddress(
    deployment.bnbInfrastructure.pancakeV3Quoter,
  ),
  pancakeV3PositionManager: getAddress(
    deployment.bnbInfrastructure.pancakeV3PositionManager,
  ),
} as const;

