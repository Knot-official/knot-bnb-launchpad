// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {KnotV3TokenDeployer} from "./KnotV3TokenDeployer.sol";
import {KnotV3LiquidityDeployer} from "./KnotV3LiquidityDeployer.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter} from "@pancakeswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IWBNB} from "../interfaces/IV3.sol";
import {QuoteRegistry} from "../QuoteRegistry.sol";
import {KnotV3Token} from "./KnotV3Token.sol";
import {KnotV3Liquidity} from "./KnotV3Liquidity.sol";
import {KnotV3FeeVault} from "./KnotV3FeeVault.sol";
import {KnotV3VaultDeployer} from "./KnotV3VaultDeployer.sol";

contract KnotV3Factory is Ownable2Step, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;
    QuoteRegistry public registry;
    KnotV3FeeVault public vault;
    KnotV3Liquidity public locker;
    address public tokenImplementation;
    address public wrappedNative;
    address public router;
    uint256 public launchFee;
    uint256 public constant taxVersion = 3;
    uint256 public constant feeVersion = 3;
    uint256 public constant continuousVersion = 1;
    uint256 public constant GRADUATION_BPS = 8000;
    bool public launchesPaused;
    mapping(address => bool) public isLaunch;
    struct Rewards { uint16 dividendBps; uint16 buybackBps; }
    event TokenLaunched(address indexed token, address indexed creator, address indexed quote,
        address curve, string name, string symbol, string metadataURI, uint8 mode, uint256 virtualQuote);
    event LaunchesPaused(bool paused);

    constructor() Ownable(address(1)) { _disableInitializers(); }

    function initialize(address owner_, address treasury_, address registry_, address wrapped_, address manager_,
        address router_, uint256 fee_, KnotV3VaultDeployer deployer, KnotV3TokenDeployer tokenDeployer, KnotV3LiquidityDeployer liquidityDeployer) external initializer
    {
        require(registry_.code.length > 0 && wrapped_.code.length > 0 && router_.code.length > 0
            && fee_ <= 1 ether, "CONFIG");
        require(owner_ != address(0), "OWNER");
        _transferOwnership(owner_);
        registry = QuoteRegistry(registry_); wrappedNative = wrapped_; router = router_; launchFee = fee_;
        vault = deployer.deploy(treasury_);
        require(vault.factory() == address(this) && vault.treasury() == treasury_, "VAULT_BINDING");
        vault.setSweepOperator(owner_);
        locker = liquidityDeployer.deploy(manager_, vault);
        vault.authorize(address(locker)); vault.bindLiquidityCollector(address(locker));
        tokenImplementation = tokenDeployer.deploy();
    }
    function curves(address) external pure returns (address) { return address(0); }
    function isCurve(address) external pure returns (bool) { return false; }
    function setFeeSweepOperator(address operator) external onlyOwner { vault.setSweepOperator(operator); }
    function setLaunchesPaused(bool paused) external onlyOwner { launchesPaused = paused; emit LaunchesPaused(paused); }

    /// @notice Atomic token-only liquidity and optional creator purchase. No migration or extra trading tax.
    function launchContinuous(string calldata name, string calldata symbol, string calldata uri,
        address quote, bytes32 salt, Rewards calldata rewards, uint256 creatorInput, uint256 minimum,
        uint256 deadline) external payable nonReentrant returns (address token, address pool, uint256 positionId, uint256 creatorOutput)
    {
        require(!launchesPaused && bytes(name).length > 0 && bytes(name).length <= 64
            && bytes(symbol).length > 0 && bytes(symbol).length <= 12 && bytes(uri).length <= 2048, "LAUNCH");
        require(uint256(rewards.dividendBps) + rewards.buybackBps <= 10000, "ALLOCATION");
        require(deadline >= block.timestamp && deadline <= block.timestamp + 5 minutes, "DEADLINE");
        require(msg.value == launchFee + (quote == wrappedNative ? creatorInput : 0), "VALUE");
        require(creatorInput == 0 || minimum > 0, "MINIMUM");
        QuoteRegistry.Quote memory cfg = registry.approved(quote);
        token = Clones.cloneDeterministic(tokenImplementation, keccak256(abi.encode(msg.sender, salt)));
        KnotV3Token launch = KnotV3Token(token);
        launch.initialize(name, symbol, uri, address(this));
        isLaunch[token] = true; vault.register(token, msg.sender, address(locker)); vault.registerPair(token, quote);
        // Shared event format; mode 2 identifies continuous V3 trading independently of graduation.
        emit TokenLaunched(token, msg.sender, quote, address(0), name, symbol, uri, 2, cfg.virtualReserve);
        pool = locker.prepare(token, quote, cfg.virtualReserve);
        address[] memory assets = new address[](1); assets[0] = quote;
        launch.configureTax(KnotV3Token.TaxConfig(0, 0, 0, 0, rewards.dividendBps, rewards.buybackBps),
            address(0), address(0), address(0), address(locker), vault.treasury(), assets);
        launch.excludePool(pool);
        IERC20(token).forceApprove(address(locker), launch.SUPPLY());
        positionId = locker.seed(token, quote);
        IERC20(token).forceApprove(address(locker), 0);
        vault.depositLaunchFee{value: launchFee}();
        if (creatorInput != 0) {
            uint256 previous = IERC20(quote).balanceOf(address(this));
            if (quote == wrappedNative) IWBNB(wrappedNative).deposit{value: creatorInput}();
            else IERC20(quote).safeTransferFrom(msg.sender, address(this), creatorInput);
            require(IERC20(quote).balanceOf(address(this)) - previous == creatorInput, "TRANSFER_TAX");
            IERC20(quote).forceApprove(router, creatorInput);
            creatorOutput = ISwapRouter(router).exactInputSingle(ISwapRouter.ExactInputSingleParams(
                quote, token, 10000, msg.sender, deadline, creatorInput, minimum, 0));
            IERC20(quote).forceApprove(router, 0);
            uint256 refund = IERC20(quote).balanceOf(address(this)) - previous;
            if (refund != 0) IERC20(quote).safeTransfer(msg.sender, refund);
        }
    }
}
