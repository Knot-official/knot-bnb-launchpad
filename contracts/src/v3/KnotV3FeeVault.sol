// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchToken} from "../LaunchToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFeeHook {
    function swapFees(address token, address quote, address inputAsset, uint256 input, uint256 minimum) external returns (uint256 spent, uint256 output);
}
interface IFeeMarkets { function positions(uint256 id) external view returns(address,address,address,uint128); function tokenPosition(address token) external view returns(uint256); }
interface IFeeCheckpoint {
    function manager() external view returns (address);
    function collectForToken(address token) external;
}

/// @notice Pull payments. A failed recipient cannot halt swaps or another recipient's claim.
contract KnotV3FeeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable factory;
    address public immutable treasury;
    uint256 public constant PROTOCOL_BPS = 4000;
    uint256 public constant MAX_INTERNAL_PRICE_IMPACT_BPS = 300;
    uint256 public constant feeVersion = 3;
    address public sweepOperator;
    mapping(address => uint256) public totalBurned;
    mapping(address => mapping(address => bool)) public marketPairs;
    struct Pending {
        uint256 quoteFees;
        uint256 tokenFees;
        uint256 buybackQuote;
        uint256 buybackToken;
        uint256 quoteClaims;
        uint256 tokenClaims;
    }
    mapping(address => mapping(address => Pending)) public pendingFees;
    event FeePending(address indexed token, address indexed quote, address indexed asset, uint256 amount, uint256 buyback);
    event BuybackBurned(address indexed token, address indexed quote, uint256 spent, uint256 burned);
    event CreatorShareAllocated(address indexed token, address indexed quote, uint256 dividends, uint256 buyback, uint256 creator);
    event SweepOperatorChanged(address indexed operator);
    event FeesSwept(address indexed token, address indexed quote, uint256 protocolAmount, uint256 creatorAmount,
        uint256 converted, uint256 buybackSpent, uint256 tokensBurned);
    error SweepQuote(uint256 converted, uint256 spent, uint256 locked, uint256 revenue);
    mapping(address => address) public creators;
    mapping(address => bool) public depositors;
    mapping(address => mapping(address => uint256)) public claimable;
    mapping(address => mapping(address => uint256)) public earned;
    mapping(address => address) public pendingCreator;
    address public liquidityCollector;
    bool private changingCreator;
    bool private collecting;

    struct Takeover {
        address recipient;
        uint64 executableAt;
    }
    mapping(address => Takeover) public takeovers;
    event FeesAccrued(
        address indexed token,
        address indexed asset,
        address indexed creator,
        uint256 creatorAmount,
        uint256 protocolAmount
    );
    event FeesClaimed(address indexed account, address indexed asset, address indexed recipient, uint256 amount);
    event CreatorProposed(address indexed token, address indexed recipient);
    event CreatorChanged(address indexed token, address indexed previous, address indexed recipient);
    event TakeoverProposed(address indexed token, address indexed recipient, uint64 executableAt);
    event TakeoverCancelled(address indexed token);

    constructor(address factory_, address treasury_) {
        require(factory_ != address(0), "FACTORY");
        factory = factory_;
        require(treasury_ != address(0), "TREASURY");
        treasury = treasury_;
    }

    function register(address token, address creator, address depositor) external {
        require(msg.sender == factory && creators[token] == address(0) && creator != address(0), "REGISTER");
        creators[token] = creator;
        depositors[depositor] = true;
    }

    function authorize(address depositor) external {
        require(msg.sender == factory, "FACTORY");
        depositors[depositor] = true;
    }

    function bindLiquidityCollector(address collector) external {
        require(msg.sender == factory && liquidityCollector == address(0) && collector.code.length > 0, "COLLECTOR");
        liquidityCollector = collector;
    }

    function registerPair(address token, address quote) external {
        require(msg.sender == factory && creators[token] != address(0) && quote != token, "FACTORY_PAIR");
        marketPairs[token][quote] = true;
    }
    function setSweepOperator(address operator) external {
        require(msg.sender == factory && operator != address(0), "FACTORY_OPERATOR");
        sweepOperator = operator;
        emit SweepOperatorChanged(operator);
    }
    function buybackEnabled(address token) public view returns (bool) {
        (,,, uint16 extraBuyback,, uint16 creatorBuyback) = LaunchToken(token).taxConfig();
        return extraBuyback != 0 || creatorBuyback != 0;
    }

    function deposit(address token, address asset, uint256 amount) external nonReentrant {
        require(depositors[msg.sender] && creators[token] != address(0) && marketPairs[token][asset], "DEPOSITOR");
        _pull(asset, msg.sender, amount);
        _accrue(token, asset, asset, amount, false);
    }

    function depositPoolFees(address token, address quote, uint256 quoteAmount, uint256 tokenAmount) external {
        require(!_reentrancyGuardEntered() || collecting, "COLLECTION_CONTEXT");
        require(msg.sender == liquidityCollector && marketPairs[token][quote], "COLLECTOR");
        if (quoteAmount != 0) { _pull(quote, msg.sender, quoteAmount); _accrue(token, quote, quote, quoteAmount, false); }
        if (tokenAmount != 0) { _pull(token, msg.sender, tokenAmount); _accrue(token, quote, token, tokenAmount, false); }
    }

    function _accrue(address token, address quote, address asset, uint256 amount, bool claims) private {
        (, uint16 weight) = LaunchToken(token).creatorAllocation();
        uint256 earmark = Math.mulDiv(amount - Math.mulDiv(amount, PROTOCOL_BPS, 10000), weight, 10000);
        Pending storage p = pendingFees[token][quote];
        if (asset == quote) {
            p.quoteFees += amount;
            if (claims) p.quoteClaims += amount;
        } else {
            p.tokenFees += amount;
            if (claims) p.tokenClaims += amount;
        }
        emit FeePending(token, quote, asset, amount, earmark);
    }

    /// @notice Only the operator can execute price-sensitive conversion or buyback legs.
    function sweepFees(address token, address quote, uint256 minimumConversion, uint256 minimumBuyback, uint256 deadline)
        external nonReentrant returns (uint256 converted, uint256 spent, uint256 locked)
    {
        require(marketPairs[token][quote] && deadline >= block.timestamp && deadline <= block.timestamp + 5 minutes, "SWEEP");
        require(msg.sender == sweepOperator, "SWEEP_OPERATOR_REQUIRED");
        return _sweep(token, quote, minimumConversion, minimumBuyback);
    }

    /// @notice A reverting nested simulation quotes both internal legs without persisting any state.
    function quoteSweep(address token, address quote) external nonReentrant returns (uint256 converted, uint256 spent, uint256 locked, uint256 revenue) {
        try this.simulateSweep(token, quote) { revert("QUOTE_EXPECTED"); }
        catch (bytes memory reason) {
            if (reason.length != 132 || bytes4(reason) != SweepQuote.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            assembly ("memory-safe") {
                converted := mload(add(reason, 36))
                spent := mload(add(reason, 68))
                locked := mload(add(reason, 100))
                revenue := mload(add(reason, 132))
            }
        }
    }
    function simulateSweep(address token, address quote) external {
        require(msg.sender == address(this) && _reentrancyGuardEntered(), "SELF");
        uint256 beforeEarned = earned[token][quote];
        (uint256 converted, uint256 spent, uint256 locked) = _sweep(token, quote, 1, 1);
        revert SweepQuote(converted, spent, locked, earned[token][quote] - beforeEarned);
    }

    function _sweep(address token, address quote, uint256 minimumConversion, uint256 minimumBuyback)
        private returns (uint256 converted, uint256 spent, uint256 locked)
    {
        require(marketPairs[token][quote], "PAIR");
        collecting = true;
        IFeeCheckpoint(liquidityCollector).collectForToken(token);
        collecting = false;
        Pending storage p = pendingFees[token][quote];
        if (p.tokenFees != 0) {
            require(minimumConversion > 0, "MINIMUM_REQUIRED");
            (uint256 consumed, uint256 received) = _poolSwap(token, quote, token, p.tokenFees, minimumConversion);
            converted = received;
            p.tokenFees -= consumed;
            p.quoteFees += received;
        }
        (uint256 creatorAmount, uint256 protocolAmount, uint256 total) = _allocate(token, quote);
        LaunchToken launch = LaunchToken(token);
        if (launch.taxEnabled()) p.buybackQuote += launch.collectBuybackFunding(quote);
        uint256 requested = p.buybackQuote;
        if (requested != 0) {
            require(minimumBuyback > 0, "MINIMUM_REQUIRED");
            uint256 beforeTokens = IERC20(token).balanceOf(address(this));
            (spent, locked) = _poolSwap(token, quote, quote, requested, minimumBuyback);
            require(spent <= requested && IERC20(token).balanceOf(address(this)) - beforeTokens == locked, "BUYBACK_ACCOUNTING");
            p.buybackQuote = requested - spent;
            if (locked != 0) {
                launch.burn(locked);
                totalBurned[token] += locked;
                emit BuybackBurned(token, quote, spent, locked);
            }
        }
        _credit(token, quote, creatorAmount, protocolAmount, total);
        emit FeesSwept(token, quote, protocolAmount, creatorAmount, converted, spent, locked);
    }

    function _allocate(address token, address quote) private returns (uint256 creatorAmount, uint256 protocolAmount, uint256 total) {
        Pending storage p = pendingFees[token][quote];
        total = p.quoteFees;
        p.quoteFees = 0;
        protocolAmount = Math.mulDiv(total, PROTOCOL_BPS, 10000);
        uint256 creatorPot = total - protocolAmount;
        (uint16 dividendWeight, uint16 buybackWeight) = LaunchToken(token).creatorAllocation();
        uint256 dividends = Math.mulDiv(creatorPot, dividendWeight, 10000);
        uint256 buyback = Math.mulDiv(creatorPot, buybackWeight, 10000);
        creatorAmount = creatorPot - dividends - buyback;
        p.buybackQuote += buyback;
        if (dividends != 0) {
            _sendDividends(token, quote, dividends);
        }
        emit CreatorShareAllocated(token, quote, dividends, buyback, creatorAmount);
    }

    function _sendDividends(address token, address quote, uint256 amount) private {
        uint256 beforeBalance = IERC20(quote).balanceOf(token);
        IERC20(quote).safeTransfer(token, amount);
        require(IERC20(quote).balanceOf(token) - beforeBalance == amount, "OUTPUT_TAX");
        LaunchToken(token).fundDividends(quote, amount);
    }

    function _credit(address token, address asset, uint256 creatorAmount, uint256 protocolAmount, uint256 total) private {
        address creator = creators[token];
        claimable[creator][asset] += creatorAmount;
        claimable[treasury][asset] += protocolAmount;
        earned[token][asset] += total;
        emit FeesAccrued(token, asset, creator, creatorAmount, protocolAmount);
    }
    function _pull(address asset, address from, uint256 amount) private {
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        require(IERC20(asset).balanceOf(address(this)) - beforeBalance == amount, "TRANSFER_TAX");
    }
    function _poolSwap(address token, address quote, address inputAsset, uint256 input, uint256 minimum)
        private returns (uint256 spent, uint256 output)
    {
        IERC20(inputAsset).forceApprove(liquidityCollector, input);
        (spent, output) = IFeeHook(liquidityCollector).swapFees(token, quote, inputAsset, input, minimum);
        IERC20(inputAsset).forceApprove(liquidityCollector, 0);
    }

    function claim(address asset, address recipient) external nonReentrant returns (uint256 amount) {
        require(recipient != address(0), "RECIPIENT");
        amount = claimable[msg.sender][asset];
        claimable[msg.sender][asset] = 0;
        if (amount != 0) {
            if (asset == address(0)) {
                (bool ok,) = recipient.call{value: amount}("");
                require(ok, "NATIVE");
            } else {
                IERC20(asset).safeTransfer(recipient, amount);
            }
        }
        emit FeesClaimed(msg.sender, asset, recipient, amount);
    }

    function depositLaunchFee() external payable {
        require(msg.sender == factory, "FACTORY");
        claimable[treasury][address(0)] += msg.value;
    }

    function proposeCreator(address token, address recipient) external {
        require(msg.sender == creators[token] && recipient != address(0), "CREATOR");
        pendingCreator[token] = recipient;
        emit CreatorProposed(token, recipient);
    }

    function acceptCreator(address token) external {
        require(msg.sender == pendingCreator[token], "RECIPIENT");
        delete pendingCreator[token];
        _changeCreator(token, msg.sender);
    }

    /// @dev Administrative recovery has a public 3-day delay and a 3-day execution window.
    function proposeTakeover(address token, address recipient) external {
        require(msg.sender == treasury && creators[token] != address(0) && recipient != address(0), "GOVERNANCE");
        uint64 eta = uint64(block.timestamp + 3 days);
        takeovers[token] = Takeover(recipient, eta);
        emit TakeoverProposed(token, recipient, eta);
    }

    function cancelTakeover(address token) external {
        require(msg.sender == treasury, "GOVERNANCE");
        delete takeovers[token];
        emit TakeoverCancelled(token);
    }

    function executeTakeover(address token) external {
        Takeover memory p = takeovers[token];
        require(
            p.recipient != address(0) && block.timestamp >= p.executableAt
                && block.timestamp <= p.executableAt + 3 days,
            "WINDOW"
        );
        delete takeovers[token];
        delete pendingCreator[token];
        _changeCreator(token, p.recipient);
    }

    function _changeCreator(address token, address recipient) private {
        // deposit() must remain callable during the checkpoint, while nested handovers
        // and handovers from a token callback during deposit/claim must be rejected.
        require(!changingCreator && !_reentrancyGuardEntered(), "CREATOR_REENTRANCY");
        require(liquidityCollector != address(0), "COLLECTOR");
        changingCreator = true;
        address previous = creators[token];
        IFeeCheckpoint(liquidityCollector).collectForToken(token);
        (,address quote,,)=IFeeMarkets(liquidityCollector).positions(IFeeMarkets(liquidityCollector).tokenPosition(token));
        Pending storage p=pendingFees[token][quote];
        require(p.quoteFees==0 && p.tokenFees==0, "SETTLE_FEES_FIRST");
        creators[token] = recipient;
        changingCreator = false;
        emit CreatorChanged(token, previous, recipient);
    }
}
