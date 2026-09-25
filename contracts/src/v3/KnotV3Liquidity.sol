// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IPositionManager, IV3Factory} from "../interfaces/IV3.sol";
import {KnotV3FeeVault} from "./KnotV3FeeVault.sol";

interface IKnotV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function swap(address recipient, bool zeroForOne, int256 amount, uint160 limit, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

/// @notice Owns the original NFT forever. No approval, transfer, decrease or rescue path exists.
contract KnotV3Liquidity is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    uint24 public constant POOL_FEE = 10000;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    int24 private constant EDGE = 887200;
    address public immutable factory;
    IPositionManager public immutable manager;
    KnotV3FeeVault public immutable vault;
    struct Position { address token; address quote; address pool; uint128 liquidity; }
    struct Range { uint160 lower; uint160 upper; uint256 initialTokens; }
    mapping(uint256 => Position) public positions;
    mapping(uint256 => Range) public ranges;
    mapping(address => uint256) public tokenPosition;
    mapping(address => address) public preparedPool;
    mapping(address => int24) public startTicks;
    address private callbackPool;
    address private callbackAsset;
    uint256 private callbackBudget;
    event LiquidityLocked(address indexed token, address indexed quote, address indexed pool,
        uint256 positionId, uint128 liquidity, uint256 tokenAmount, uint256 quoteAmount);
    event ContinuousPosition(address indexed token, uint256 indexed positionId, uint160 sqrtLowerX96,
        uint160 sqrtUpperX96, uint128 liquidity, uint256 initialTokens);
    event FeesCollected(address indexed token, uint256 indexed positionId, uint256 quoteAmount, uint256 burnedAmount);

    constructor(address factory_, address manager_, KnotV3FeeVault vault_) {
        require(factory_ != address(0) && manager_.code.length > 0, "CONFIG");
        factory = factory_; manager = IPositionManager(manager_); vault = vault_;
        require(IV3Factory(manager.factory()).feeAmountTickSpacing(POOL_FEE) == 200, "FEE_TIER");
    }

    /// @notice QuoteRegistry.virtualReserve is the starting quote market capitalization for this mode.
    function prepare(address token, address quote, uint256 startingQuoteCap) external returns (address pool) {
        require(msg.sender == factory && preparedPool[token] == address(0) && token != quote, "FACTORY");
        (address a, address b) = token < quote ? (token, quote) : (quote, token);
        require(IV3Factory(manager.factory()).getPool(a, b, POOL_FEE) == address(0), "POOL_EXISTS");
        uint256 ratio = token < quote
            ? Math.mulDiv(startingQuoteCap, uint256(1) << 128, SUPPLY)
            : Math.mulDiv(SUPPLY, uint256(1) << 128, startingQuoteCap);
        uint256 root = Math.sqrt(ratio) << 32;
        require(root > TickMath.MIN_SQRT_PRICE && root < TickMath.MAX_SQRT_PRICE, "PRICE");
        int24 tick = TickMath.getTickAtSqrtPrice(uint160(root));
        // Mathematical floor; Solidity signed division otherwise rounds toward zero.
        int24 start = (tick / 200) * 200;
        if (tick < 0 && tick % 200 != 0) start -= 200;
        require(start > -EDGE && start < EDGE, "RANGE");
        pool = manager.createAndInitializePoolIfNecessary(a, b, POOL_FEE, TickMath.getSqrtPriceAtTick(start));
        preparedPool[token] = pool; startTicks[token] = start;
    }

    function seed(address token, address quote) external nonReentrant returns (uint256 id) {
        address pool = preparedPool[token];
        require(msg.sender == factory && pool != address(0) && tokenPosition[token] == 0, "FACTORY");
        require(IV3Factory(manager.factory()).getPool(token, quote, POOL_FEE) == pool, "PAIR");
        IERC20(token).safeTransferFrom(factory, address(this), SUPPLY);
        IERC20(token).forceApprove(address(manager), SUPPLY);
        bool first = token < quote;
        int24 lower = first ? startTicks[token] : -EDGE;
        int24 upper = first ? EDGE : startTicks[token];
        uint128 liquidity; uint256 a; uint256 b;
        (id, liquidity, a, b) = manager.mint(IPositionManager.MintParams({
            token0: first ? token : quote, token1: first ? quote : token, fee: POOL_FEE,
            tickLower: lower, tickUpper: upper, amount0Desired: first ? SUPPLY : 0,
            amount1Desired: first ? 0 : SUPPLY, amount0Min: first ? SUPPLY - 1e12 : 0,
            amount1Min: first ? 0 : SUPPLY - 1e12, recipient: address(this), deadline: block.timestamp
        }));
        IERC20(token).forceApprove(address(manager), 0);
        uint256 used = first ? a : b;
        require(id != 0 && liquidity > 0 && used > 0 && (first ? b : a) == 0, "LIQUIDITY");
        positions[id] = Position(token, quote, pool, liquidity);
        ranges[id] = Range(TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), used);
        tokenPosition[token] = id;
        emit LiquidityLocked(token, quote, pool, id, liquidity, used, 0);
        emit ContinuousPosition(token, id, ranges[id].lower, ranges[id].upper, liquidity, used);
    }

    function positionIds(address token) external view returns (uint256[] memory ids) {
        uint256 id = tokenPosition[token]; ids = new uint256[](id == 0 ? 0 : 1);
        if (id != 0) ids[0] = id;
    }
    function remainingTokens(uint256 id) external view returns (uint256) {
        Position memory p = positions[id]; Range memory r = ranges[id];
        require(p.token != address(0), "POSITION");
        (uint160 price,,,,,,) = IKnotV3Pool(p.pool).slot0();
        price = uint160(Math.max(r.lower, Math.min(price, r.upper)));
        return p.token < p.quote
            ? SqrtPriceMath.getAmount0Delta(price, r.upper, p.liquidity, true)
            : SqrtPriceMath.getAmount1Delta(r.lower, price, p.liquidity, true);
    }
    function collect(uint256 id) external nonReentrant returns (uint256 quoteAmount, uint256 burned) { return _collect(id); }
    function collectForToken(address token) external nonReentrant {
        require(msg.sender == address(vault), "VAULT"); _collect(tokenPosition[token]);
    }
    function _collect(uint256 id) private returns (uint256 quoteAmount, uint256 burned) {
        Position memory p = positions[id]; require(p.token != address(0), "POSITION");
        (uint256 a, uint256 b) = manager.collect(IPositionManager.CollectParams(id, address(this), type(uint128).max, type(uint128).max));
        uint256 tokenAmount; (tokenAmount, quoteAmount) = p.token < p.quote ? (a, b) : (b, a);
        if (quoteAmount != 0 || tokenAmount != 0) {
            IERC20(p.quote).forceApprove(address(vault), quoteAmount);
            IERC20(p.token).forceApprove(address(vault), tokenAmount);
            vault.depositPoolFees(p.token, p.quote, quoteAmount, tokenAmount);
            IERC20(p.quote).forceApprove(address(vault), 0);
            IERC20(p.token).forceApprove(address(vault), 0);
        }
        emit FeesCollected(p.token, id, quoteAmount, 0);
        return (quoteAmount, 0);
    }

    /// @notice Fee processing is bounded to ~3% price movement per leg, with an operator minimum output.
    function swapFees(address token, address quote, address inputAsset, uint256 input, uint256 minimum)
        external nonReentrant returns (uint256 spent, uint256 output)
    {
        Position memory p = positions[tokenPosition[token]];
        require(msg.sender == address(vault) && p.quote == quote && p.token == token
            && (inputAsset == token || inputAsset == quote) && input > 0
            && input <= uint256(type(int256).max) && minimum > 0, "FEE_SWAP");
        bool zeroForOne = inputAsset < (inputAsset == token ? quote : token);
        (uint160 price,,,,,,) = IKnotV3Pool(p.pool).slot0();
        uint256 bound = zeroForOne ? Math.mulDiv(price, 9850, 10000) : Math.mulDiv(price, 10148, 10000);
        Range memory range = ranges[tokenPosition[token]];
        bound = zeroForOne ? Math.max(bound, range.lower) : Math.min(bound, range.upper);
        uint160 limit = uint160(Math.max(TickMath.MIN_SQRT_PRICE + 1, Math.min(bound, TickMath.MAX_SQRT_PRICE - 1)));
        if ((zeroForOne && limit >= price) || (!zeroForOne && limit <= price)) return (0, 0);
        address outputAsset = inputAsset == token ? quote : token;
        uint256 beforeInput = IERC20(inputAsset).balanceOf(address(vault));
        uint256 beforeOutput = IERC20(outputAsset).balanceOf(address(vault));
        callbackPool = p.pool; callbackAsset = inputAsset; callbackBudget = input;
        (int256 a, int256 b) = IKnotV3Pool(p.pool).swap(address(vault), zeroForOne, int256(input), limit, "");
        callbackPool = address(0); callbackAsset = address(0); callbackBudget = 0;
        int256 paid = zeroForOne ? a : b; int256 received = zeroForOne ? b : a;
        require(paid >= 0 && received <= 0, "SWAP_DELTAS");
        spent = uint256(paid); output = uint256(-received);
        require(spent <= input && output >= minimum, "SLIPPAGE");
        require(beforeInput - IERC20(inputAsset).balanceOf(address(vault)) == spent
            && IERC20(outputAsset).balanceOf(address(vault)) - beforeOutput == output, "SWAP_ACCOUNTING");
    }
    function pancakeV3SwapCallback(int256 a, int256 b, bytes calldata) external {
        require(msg.sender == callbackPool && _reentrancyGuardEntered(), "CALLBACK");
        require((a > 0 && b <= 0) || (b > 0 && a <= 0), "DELTA");
        uint256 owed = uint256(a > 0 ? a : b);
        require(owed <= callbackBudget, "BUDGET"); callbackBudget -= owed;
        IERC20(callbackAsset).safeTransferFrom(address(vault), msg.sender, owed);
    }
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(manager), "NFT"); return this.onERC721Received.selector;
    }
}
