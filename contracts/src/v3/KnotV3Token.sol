// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRewardFactory { function vault() external view returns (address); }
interface IRewardFeeVault { function creators(address token) external view returns (address); }

/// @notice Fixed supply, plain ERC20 transfers and immutable creator-funded holder rewards.
contract KnotV3Token is ERC20Burnable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant MIN_REWARD_BALANCE = 1;
    uint256 public constant dividendVersion = 3;
    uint256 public constant MAX_DIVIDEND_BATCH = 32;
    uint256 private constant DELIVERY_GAS = 250_000;
    uint256 private constant MAGNITUDE = 1e27;
    address public immutable factory;
    bool private initialized;
    string private tokenName;
    string private tokenSymbol;
    string public metadataURI;
    // Each allocation applies to its own pot; the unallocated remainder is creator cash.
    struct TaxConfig {
        uint16 buyBps;
        uint16 sellBps;
        uint16 extraDividendBps;
        uint16 extraBuybackBps;
        uint16 creatorDividendBps;
        uint16 creatorBuybackBps;
    }
    TaxConfig public taxConfig;
    bool public taxEnabled;
    address public taxCurve;
    address public taxHook;
    address public taxTreasury;
    address public rewardVault;
    address public canonicalPool;
    address[] public rewardAssets;
    mapping(address => bool) public isRewardAsset;
    mapping(address => bool) public rewardExcluded;
    mapping(address => uint256) public rewardShares;
    uint256 public eligibleSupply;
    mapping(address => uint256) public magnifiedDividendPerShare;
    mapping(address => mapping(address => int256)) private corrections;
    mapping(address => mapping(address => uint256)) public dividendsWithdrawn;
    mapping(address => mapping(address => uint256)) public taxCredits;
    mapping(address => uint256) public accountedRewards;
    mapping(address => uint256) public lifetimeFunded;
    mapping(address => uint256) public pendingBuyback;
    mapping(address => uint256) public pendingDividends;
    event TaxConfigured(uint16 buyBps, uint16 sellBps, uint16 extraDividendBps, uint16 extraBuybackBps,
        uint16 creatorDividendBps, uint16 creatorBuybackBps, address indexed treasury, address[] assets);
    event TaxAccrued(address indexed asset, bool isBuy, uint256 gross, uint256 tax, uint256 protocol,
        uint256 creator, uint256 dividends, uint256 buyback);
    event DividendsFunded(address indexed asset, uint256 amount);
    event BuybackFundingCollected(address indexed asset, uint256 amount);
    event DividendsClaimed(address indexed account, address indexed asset, address indexed recipient, uint256 amount);
    event DividendDeliveryDeferred(address indexed account, address indexed asset);
    event TaxProceedsClaimed(address indexed account, address indexed asset, address indexed recipient, uint256 amount);

    constructor(address factory_) ERC20("", "") {
        require(factory_ != address(0), "FACTORY");
        factory = factory_;
        initialized = true;
    }

    function initialize(string calldata name_, string calldata symbol_, string calldata uri_, address recipient)
        external
    {
        require(msg.sender == factory && !initialized, "INIT");
        initialized = true;
        tokenName = name_;
        tokenSymbol = symbol_;
        metadataURI = uri_;
        _mint(recipient, SUPPLY);
    }

    function name() public view override returns (string memory) {
        return tokenName;
    }

    function symbol() public view override returns (string memory) {
        return tokenSymbol;
    }

    /// @dev Factory calls this atomically after minting protocol inventory and before any user transfer.
    function configureTax(TaxConfig calldata cfg, address curve, address hook, address manager,
        address locker, address treasury, address[] calldata assets) external
    {
        require(msg.sender == factory && initialized && !taxEnabled, "TAX_INIT");
        require(cfg.buyBps <= 1000 && cfg.sellBps <= 1000
            && uint256(cfg.extraDividendBps) + cfg.extraBuybackBps <= 10000
            && uint256(cfg.creatorDividendBps) + cfg.creatorBuybackBps <= 10000, "TAX_CONFIG");
        require(hook == address(0) && manager == address(0) && cfg.buyBps == 0 && cfg.sellBps == 0
            && cfg.extraDividendBps == 0 && cfg.extraBuybackBps == 0 && treasury != address(0)
            && assets.length > 0 && assets.length <= 2, "TAX_BINDINGS");
        // No factory path can configure an already circulating token.
        require(balanceOf(factory) + (curve == address(0) ? 0 : balanceOf(curve)) == SUPPLY, "INVENTORY");
        taxEnabled = true;
        taxConfig = cfg;
        taxCurve = curve;
        taxHook = hook;
        taxTreasury = treasury;
        rewardExcluded[address(0)] = true;
        rewardExcluded[address(0xdead)] = true;
        rewardExcluded[address(this)] = true;
        rewardExcluded[factory] = true;
        rewardExcluded[curve] = true;
        rewardExcluded[hook] = true;
        rewardExcluded[manager] = true;
        rewardExcluded[locker] = true;
        address escrow = IRewardFactory(factory).vault();
        rewardVault = escrow;
        rewardExcluded[escrow] = true;
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            require(asset.code.length > 0 && asset != address(this) && !isRewardAsset[asset], "REWARD_ASSET");
            isRewardAsset[asset] = true;
            rewardAssets.push(asset);
        }
        emit TaxConfigured(cfg.buyBps, cfg.sellBps, cfg.extraDividendBps, cfg.extraBuybackBps,
            cfg.creatorDividendBps, cfg.creatorBuybackBps, treasury, assets);
    }

    function marketTax(uint256 gross, bool isBuy) public view returns (uint256) {
        return Math.mulDiv(gross, taxRate(isBuy), 10000, Math.Rounding.Ceil);
    }

    function taxRate(bool isBuy) public view returns (uint256) { return isBuy ? taxConfig.buyBps : taxConfig.sellBps; }

    /// @notice Base-fee dividends arrive in the pairing asset from the fee vault.
    function fundDividends(address asset, uint256 amount) external nonReentrant {
        require(msg.sender == rewardVault && isRewardAsset[asset], "FEE_VAULT");
        _accountFunding(asset, amount);
        _fundDividends(asset, amount);
    }

    function _accountFunding(address asset, uint256 amount) private {
        lifetimeFunded[asset] += amount;
        require(lifetimeFunded[asset] <= type(uint128).max, "REWARD_CAP");
        accountedRewards[asset] += amount;
        require(rewardBacking(asset) >= accountedRewards[asset], "UNFUNDED");
    }

    function _fundDividends(address asset, uint256 amount) private {
        uint256 available = amount + pendingDividends[asset];
        if (eligibleSupply == 0) pendingDividends[asset] = available;
        else {
            // This bound supports even a one-wei holder without signed correction overflow.
            uint256 next = magnifiedDividendPerShare[asset] + Math.mulDiv(available, MAGNITUDE, eligibleSupply);
            require(next <= uint256(type(int256).max) / SUPPLY / 4, "DIVIDEND_PRECISION_CAP");
            magnifiedDividendPerShare[asset] = next;
            pendingDividends[asset] = 0;
        }
        emit DividendsFunded(asset, amount);
    }

    /// @dev Retained for the common reward-worker interface; extra-tax funding is always zero.
    function collectBuybackFunding(address asset) external nonReentrant returns (uint256 amount) {
        require(msg.sender == rewardVault && isRewardAsset[asset], "FEE_VAULT");
        amount = pendingBuyback[asset];
        pendingBuyback[asset] = 0;
        if (amount != 0) _payReward(asset, msg.sender, amount);
        emit BuybackFundingCollected(asset, amount);
    }

    function creatorAllocation() external view returns (uint16 dividends, uint16 buyback) {
        return (taxConfig.creatorDividendBps, taxConfig.creatorBuybackBps);
    }

    function claimableDividend(address asset, address account) public view returns (uint256) {
        int256 accrued = int256(magnifiedDividendPerShare[asset] * rewardShares[account]) + corrections[asset][account];
        return uint256(accrued) / MAGNITUDE - dividendsWithdrawn[asset][account];
    }

    function claimDividend(address asset, address recipient) external nonReentrant returns (uint256 amount) {
        return _claimDividend(asset, msg.sender, recipient);
    }

    /// @notice Anyone may pay the gas to deliver a holder's earnings, only to that holder.
    /// Creator/marketing/treasury credits are never touched by automatic delivery.
    function distributeDividend(address asset, address account) external nonReentrant returns (uint256 amount) {
        require(isRewardAsset[asset], "REWARD_ASSET");
        if (claimableDividend(asset, account) == 0) return 0;
        return _claimDividend(asset, account, account);
    }

    /// @notice Bounded, independent deliveries. A blocked recipient cannot hold up other holders.
    function distributeDividends(address asset, address[] calldata accounts)
        external nonReentrant returns (uint256 delivered, uint256 total)
    {
        require(isRewardAsset[asset] && accounts.length > 0 && accounts.length <= MAX_DIVIDEND_BATCH, "DELIVERY_BATCH");
        for (uint256 i; i < accounts.length; ++i) {
            // Preserve gas for the caller and batch bookkeeping even if a quote token consumes its allowance.
            require(gasleft() > DELIVERY_GAS + 30_000, "DELIVERY_GAS");
            try this.executeDividendPayment{gas: DELIVERY_GAS}(asset, accounts[i]) returns (uint256 amount) {
                if (amount > 0) { ++delivered; total += amount; }
            } catch {
                emit DividendDeliveryDeferred(accounts[i], asset);
            }
        }
    }

    /// @dev The external self-call isolates failed pairing-asset transfers per recipient.
    function executeDividendPayment(address asset, address account) external returns (uint256 amount) {
        require(msg.sender == address(this) && _reentrancyGuardEntered(), "DELIVERY_SELF");
        if (claimableDividend(asset, account) == 0) return 0;
        return _claimDividend(asset, account, account);
    }

    function _claimDividend(address asset, address account, address recipient) private returns (uint256 amount) {
        amount = claimableDividend(asset, account);
        require(amount > 0, "NO_DIVIDENDS");
        dividendsWithdrawn[asset][account] += amount;
        _payReward(asset, recipient, amount);
        emit DividendsClaimed(account, asset, recipient, amount);
    }

    function claimTaxProceeds(address asset, address recipient) external nonReentrant returns (uint256 amount) {
        amount = taxCredits[asset][msg.sender];
        require(amount > 0, "NO_PROCEEDS");
        taxCredits[asset][msg.sender] = 0;
        _payReward(asset, recipient, amount);
        emit TaxProceedsClaimed(msg.sender, asset, recipient, amount);
    }

    function _payReward(address asset, address recipient, uint256 amount) private {
        require(isRewardAsset[asset] && recipient != address(0) && recipient != address(this), "RECIPIENT");
        accountedRewards[asset] -= amount;
        uint256 held = IERC20(asset).balanceOf(address(this));
        require(held >= amount, "REWARD_BACKING");
        uint256 beforeBalance = IERC20(asset).balanceOf(recipient);
        IERC20(asset).safeTransfer(recipient, amount);
        require(IERC20(asset).balanceOf(recipient) - beforeBalance == amount, "OUTPUT_TAX");
    }

    function rewardBacking(address asset) public view returns (uint256) {
        if (!isRewardAsset[asset]) return 0;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @dev Bound by the factory before the first pool mint or creator purchase.
    function excludePool(address pool) external {
        require(msg.sender == factory && canonicalPool == address(0) && balanceOf(factory) == SUPPLY
            && pool.code.length > 0 && balanceOf(pool) == 0
            && rewardShares[pool] == 0, "POOL_BINDING");
        canonicalPool = pool;
        rewardExcluded[pool] = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (taxEnabled && from != to) { _syncShares(from); _syncShares(to); }
    }

    function _syncShares(address account) private {
        if (rewardExcluded[account]) return;
        uint256 balance = balanceOf(account);
        uint256 next = balance >= MIN_REWARD_BALANCE ? balance : 0;
        uint256 previous = rewardShares[account];
        if (next == previous) return;
        rewardShares[account] = next;
        eligibleSupply = eligibleSupply - previous + next;
        // A fixed maximum of two assets: transfer/claim cost never grows with holder count.
        for (uint256 i; i < rewardAssets.length; ++i) {
            address asset = rewardAssets[i];
            uint256 perShare = magnifiedDividendPerShare[asset];
            if (next > previous) corrections[asset][account] -= int256(perShare * (next - previous));
            else corrections[asset][account] += int256(perShare * (previous - next));
        }
    }
}
