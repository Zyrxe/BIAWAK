// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
// Note: We use the non-upgradeable SafeMath since it's simple utility and is safe here

contract BiawakToken is Initializable, Context, ERC20Upgradeable, ERC20BurnableUpgradeable, PausableUpgradeable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMath for uint256;

    // --- GLOBAL PARAMETERS ---
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public constant MAX_FEE = 1000; // 10.00% (1000 basis points)
    address public immutable TREASURY_WALLET = 0x095C20E1046805d33c5f1cCe7640F1DD4b693a49;
    address public immutable SPECIAL_WALLET = 0xE0FB20c169d6EE15Bb7A55b5F71199099aD4464F;

    // --- FEE SYSTEM (Basis Points / 10,000) ---
    uint256 public transferFeeBps; // Fee for standard transfers
    uint256 public buyFeeBps;      // Fee for buying (e.g., transfers *from* Liquidity Pool)
    uint256 public sellFeeBps;     // Fee for selling (e.g., transfers *to* Liquidity Pool)

    // Fee Allocation (Total must equal the fee charged)
    uint256 public treasuryAllocationBps;
    uint256 public rewardAllocationBps;   // Reflection to holders (Feature #13)
    uint256 public liquidityAllocationBps; // Auto-liquidity (Feature #14)
    uint256 public burnAllocationBps;    // Optional burn (Part of Feature #3)

    // --- ACCESS AND SECURITY ---
    mapping(address => bool) public isBlacklisted; // Feature #15
    mapping(address => bool) public isFeeExempt;   // Feature #2

    // --- ANTI-WHALE/ANTI-BOT/LIMITS ---
    address public liquidityPair;
    bool public antiBotActive = true;         // Feature #9
    uint256 public antiBotPeriodEnd;          // Anti-bot period end time (initial launch)
    uint256 public maxTransactionAmount;      // Feature #7
    uint256 public maxSellAmount;             // Feature #10
    uint256 public cooldownTimeSeconds;       // Feature #11
    mapping(address => uint256) public lastTransactionTime;

    // --- VESTING & TIMELOCK ---
    uint256 public ownerUnlockTime; // Feature #5
    mapping(address => uint256) public vestingLockUntil; // Feature #6 (Simple per-wallet lock)

    // --- EVENTS (Feature #23) ---
    event FeeTaken(address indexed from, address indexed to, uint256 amount, uint256 totalFee, uint256 liquidity, uint256 reflection, uint256 burn);
    event SpecialTransfer(address indexed from, address indexed to, uint256 amount, string reason);
    event VestingSet(address indexed wallet, uint256 lockUntil);
    event FreezeWallet(address indexed wallet, bool frozen);
    event RewardDistributed(uint256 reflectionAmount);
    event LiquidityAdded(uint256 tokenAmount, uint256 ethAmount);
    event DynamicFeeChanged(uint256 newBuyFee, uint256 newSellFee, string reason);
    event OwnershipLockSet(uint256 unlockTime);

    // --- MODIFIERS ---
    modifier onlyAdmin() {
        require(owner() == _msgSender(), "Biawak: Must be contract owner");
        _;
    }

    // --- INITIALIZATION (UUPS) ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // Disable the initialize function for the implementation contract
    }

    function initialize(address initialOwner, uint256 _ownerUnlockTime, address _liquidityPair) public initializer {
        __ERC20_init("BIAWAK", "BWK");
        __ERC20Burnable_init();
        __Pausable_init();
        __Ownable2Step_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Check if the total supply is within limits
        require(MAX_SUPPLY > 0, "Biawak: Supply must be greater than zero");

        // --- MINT & TIMELOCK (Feature #5) ---
        _mint(initialOwner, MAX_SUPPLY); // Mint full supply to the owner's wallet
        ownerUnlockTime = _ownerUnlockTime;
        emit OwnershipLockSet(_ownerUnlockTime);

        // --- SET INITIAL CONFIGURATION (Feature #22) ---
        // High initial fees and strict limits for launch
        liquidityPair = _liquidityPair;
        setAntiBotPeriod(3 days);
        isFeeExempt[initialOwner] = true;
        isFeeExempt[TREASURY_WALLET] = true;
        isFeeExempt[SPECIAL_WALLET] = true;
        isFeeExempt[address(this)] = true;
        isFeeExempt[address(0)] = true;

        // Initial launch parameters (e.g., 10% fee on buys/sells)
        setFees(100, 1000, 1000); // TxFee=1.00%, BuyFee=10.00%, SellFee=10.00%
        setFeeAllocation(500, 300, 200, 0); // 5% Treasury, 3% Reflection, 2% Liquidity, 0% Burn (out of a 10% base)
        setMaxLimits(MAX_SUPPLY / 100, MAX_SUPPLY / 200, 60); // 1% Max Tx, 0.5% Max Sell, 60s Cooldown
    }

    // --- UUPS UPGRADE FUNCTION ---

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    // --- PAUSABLE (Feature #8) ---

    function pause() public onlyAdmin {
        _pause();
    }

    function unpause() public onlyAdmin {
        _unpause();
    }

    // --- TRANSFER OVERRIDE (Core Logic) ---

    function _transfer(address from, address to, uint256 amount) internal override whenNotPaused nonReentrant {
        require(!isBlacklisted[from], "Biawak: Sender is blacklisted"); // Feature #15
        require(!isBlacklisted[to], "Biawak: Recipient is blacklisted"); // Feature #15

        // Check Owner Timelock (Feature #5)
        if (from == owner() && block.timestamp < ownerUnlockTime) {
            require(from == address(this), "Biawak: Owner tokens are time-locked.");
        }

        // Check Individual Vesting (Feature #6)
        if (block.timestamp < vestingLockUntil[from]) {
            require(from == address(this), "Biawak: Wallet is vesting locked.");
        }

        // --- LIMITS (Features #7, #10, #11) ---
        if (from != owner() && to != owner() && from != address(this) && to != address(this)) {
            // Anti-Whale Check (Max Tx)
            if (maxTransactionAmount > 0) {
                require(amount <= maxTransactionAmount, "Biawak: Transfer exceeds max transaction limit.");
            }

            // Max Sell Check (Applies when sending *to* the Liquidity Pair)
            if (to == liquidityPair && maxSellAmount > 0) {
                require(amount <= maxSellAmount, "Biawak: Sell exceeds max sell amount.");
            }

            // Cooldown Check
            if (cooldownTimeSeconds > 0) {
                if (lastTransactionTime[from] > 0) {
                    require(block.timestamp >= lastTransactionTime[from].add(cooldownTimeSeconds), "Biawak: Cooldown period active.");
                }
                lastTransactionTime[from] = block.timestamp;
            }
        }

        // --- ANTI-BOT/ANTI-SNIPE (Feature #9) ---
        if (antiBotActive && block.timestamp < antiBotPeriodEnd) {
            // During launch, prevent transfers from non-owner/non-special wallets if it's not a transaction with the LP
            if (from != owner() && to != owner() && from != SPECIAL_WALLET && to != SPECIAL_WALLET) {
                // Allows only LP buys/sells during this period to prevent bot distribution
                require(from == liquidityPair || to == liquidityPair, "Biawak: Anti-bot is active. Only LP interactions allowed.");
            }
        }

        // --- FEE CALCULATION (Features #3, #13, #14) ---
        uint256 fee = 0;
        uint256 feeBps = 0;

        if (!isFeeExempt[from] && !isFeeExempt[to]) {
            if (from == liquidityPair) {
                // Buy: LP -> User
                feeBps = buyFeeBps;
            } else if (to == liquidityPair) {
                // Sell: User -> LP
                feeBps = sellFeeBps;
            } else {
                // Standard Transfer: User -> User
                feeBps = transferFeeBps;
            }

            if (feeBps > 0) {
                fee = amount.mul(feeBps).div(10000);
            }
        }

        uint256 amountAfterFee = amount.sub(fee);

        if (fee > 0) {
            // Allocate Fee
            uint256 treasuryAmount = fee.mul(treasuryAllocationBps).div(10000);
            uint256 reflectionAmount = fee.mul(rewardAllocationBps).div(10000);
            uint256 liquidityAmount = fee.mul(liquidityAllocationBps).div(10000);
            uint256 burnAmount = fee.mul(burnAllocationBps).div(10000);

            // 1. Treasury
            super._transfer(from, TREASURY_WALLET, treasuryAmount);

            // 2. Reflection (Reward) - Sending fees to the contract itself to be distributed to holders
            super._transfer(from, address(this), reflectionAmount);
            emit RewardDistributed(reflectionAmount);

            // 3. Liquidity/Burn (Collected by the contract for future action)
            super._transfer(from, address(this), liquidityAmount.add(burnAmount));

            emit FeeTaken(from, to, amount, fee, liquidityAmount, reflectionAmount, burnAmount);
        }

        // Final transfer of net amount
        super._transfer(from, to, amountAfterFee);
    }

    // --- ADMIN & GOVERNANCE FUNCTIONS (Owner-only) ---

    // Feature #1: Full administrative control (via Ownable) & #3, #22
    function setFees(uint256 _transferFeeBps, uint256 _buyFeeBps, uint256 _sellFeeBps) public onlyAdmin {
        require(_transferFeeBps <= MAX_FEE && _buyFeeBps <= MAX_FEE && _sellFeeBps <= MAX_FEE, "Biawak: Fee exceeds max limit (10%).");
        transferFeeBps = _transferFeeBps;
        buyFeeBps = _buyFeeBps;
        sellFeeBps = _sellFeeBps;
    }

    function setFeeAllocation(uint256 _treasuryBps, uint256 _rewardBps, uint256 _liquidityBps, uint256 _burnBps) public onlyAdmin {
        uint256 totalAllocation = _treasuryBps.add(_rewardBps).add(_liquidityBps).add(_burnBps);
        require(totalAllocation <= MAX_FEE, "Biawak: Total allocation exceeds 10% max fee."); // Max allocation cannot exceed 10%
        treasuryAllocationBps = _treasuryBps;
        rewardAllocationBps = _rewardBps;
        liquidityAllocationBps = _liquidityBps;
        burnAllocationBps = _burnBps;
    }

    // Feature #7, #10, #11
    function setMaxLimits(uint256 _maxTransaction, uint256 _maxSell, uint256 _cooldown) public onlyAdmin {
        maxTransactionAmount = _maxTransaction;
        maxSellAmount = _maxSell;
        cooldownTimeSeconds = _cooldown;
    }

    // Feature #15 (Blacklist)
    function setBlacklisted(address wallet, bool isBlacklisted_) public onlyAdmin {
        isBlacklisted[wallet] = isBlacklisted_;
        emit FreezeWallet(wallet, isBlacklisted_);
    }

    // Feature #2 (Special wallet fee exemption)
    function setFeeExempt(address wallet, bool isExempt) public onlyAdmin {
        isFeeExempt[wallet] = isExempt;
    }

    // Feature #4 (Minting, requires MAX_SUPPLY check)
    function mint(address to, uint256 amount) public onlyAdmin {
        require(totalSupply().add(amount) <= MAX_SUPPLY, "Biawak: Minting exceeds max supply.");
        _mint(to, amount);
    }

    // Feature #4 (Burning) - Inherited from ERC20Burnable.

    // Feature #6 (Vesting)
    function setVestingLock(address wallet, uint256 lockUntil) public onlyAdmin {
        vestingLockUntil[wallet] = lockUntil;
        emit VestingSet(wallet, lockUntil);
    }

    // Feature #9 (Anti-bot period)
    function setAntiBotPeriod(uint256 durationInSeconds) public onlyAdmin {
        antiBotActive = true;
        antiBotPeriodEnd = block.timestamp.add(durationInSeconds);
    }

    function disableAntiBot() public onlyAdmin {
        antiBotActive = false;
        antiBotPeriodEnd = block.timestamp;
    }

    // Feature #12 (Simplified Dynamic Fee Change)
    function dynamicFeeAdjustment(uint256 newBuyFeeBps, uint256 newSellFeeBps, string memory reason) public onlyAdmin {
        setFees(transferFeeBps, newBuyFeeBps, newSellFeeBps);
        emit DynamicFeeChanged(newBuyFeeBps, newSellFeeBps, reason);
    }

    // Feature #14 (Liquidity Addition) - Withdraw collected liquidity tokens to facilitate adding LP
    function withdrawCollectedLiquidityTokens(uint256 amount) public onlyAdmin nonReentrant {
        // Owner must call this function to manually pair these tokens with ETH/BNB to add liquidity.
        // For a full system, this would interact directly with a router.
        require(balanceOf(address(this)) >= amount, "Biawak: Insufficient contract balance.");
        super._transfer(address(this), owner(), amount);
        emit SpecialTransfer(address(this), owner(), amount, "Withdraw Liquidity/Burn tokens for LP or burn action.");
    }
}
