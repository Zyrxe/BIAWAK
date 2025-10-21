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
// SafeMath is used for robust arithmetic operations

contract BiawakToken is Initializable, Context, ERC20Upgradeable, ERC20BurnableUpgradeable, PausableUpgradeable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMath for uint256;

    // --- GLOBAL CONSTANTS ---
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public constant MAX_FEE = 1000; // Max fee is 10.00% (1000 basis points)
    address public immutable TREASURY_WALLET = 0x095C20E1046805d33c5f1cCe7640F1DD4b693a49; // Feature #3
    address public immutable SPECIAL_WALLET = 0xE0FB20c169d6EE15Bb7A55b5F71199099aD4464F; // Feature #2

    // --- FEE SYSTEM (Basis Points / 10,000) ---
    uint256 public transferFeeBps;
    uint256 public buyFeeBps;
    uint256 public sellFeeBps;

    // Fee Allocation Ratios (Total must sum up to the charged fee)
    uint256 public treasuryAllocationBps;
    uint256 public rewardAllocationBps;    // Reflection to holders (sent to contract balance) - Feature #13
    uint256 public liquidityAllocationBps; // Collected for Auto-liquidity - Feature #14
    uint256 public burnAllocationBps;     // Collected for burning - Feature #3

    // --- ACCESS AND SECURITY ---
    mapping(address => bool) public isBlacklisted; // Feature #15 (Freeze/Blacklist)
    mapping(address => bool) public isFeeExempt;   // Feature #2 (Fee-free transfers)
    address public liquidityPair; // Address of the main DEX pair (Multi-liquidity is handled externally/in future upgrades - #20)

    // --- ANTI-WHALE/ANTI-BOT/LIMITS ---
    bool public antiBotActive = true;         // Feature #9
    uint256 public antiBotPeriodEnd;          
    uint256 public maxTransactionAmount;      // Feature #7 (Max Tx limit)
    uint256 public maxSellAmount;             // Feature #10 (Max Sell limit)
    uint256 public cooldownTimeSeconds;       // Feature #11 (Cooldown period)
    mapping(address => uint256) public lastTransactionTime;

    // --- VESTING & TIMELOCK ---
    uint256 public ownerUnlockTime; // Feature #5 (Owner tokens time-locked)
    mapping(address => uint256) public vestingLockUntil; // Feature #6 (Simple per-wallet lock)

    // --- LIQUIDITY & BURN TRACKERS ---
    uint256 public totalLiquidityTokensCollected;
    uint256 public totalBurnTokensCollected;

    // --- EVENTS (Feature #23) ---
    event FeeTaken(address indexed from, address indexed to, uint256 amount, uint256 totalFee, uint256 liquidity, uint256 reflection, uint256 burn);
    event SpecialTransfer(address indexed from, address indexed to, uint256 amount, string reason);
    event VestingSet(address indexed wallet, uint256 lockUntil);
    event FreezeWallet(address indexed wallet, bool frozen);
    event RewardDistributed(uint256 reflectionAmount);
    event LiquidityTokensWithdrawn(uint256 tokenAmount);
    event DynamicFeeChanged(uint256 newBuyFee, uint256 newSellFee, string reason);
    event OwnershipLockSet(uint256 unlockTime);
    // Snapshot and Staking events will be added in future Governor/Staking contracts

    // --- MODIFIERS ---
    modifier onlyAdmin() {
        require(owner() == _msgSender(), "Biawak: Must be contract owner");
        _;
    }

    // --- INITIALIZATION (UUPS) ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // Mandatory for implementation contract
    }

    function initialize(address initialOwner, uint256 _ownerUnlockTime, address _liquidityPair) public initializer {
        __ERC20_init("BIAWAK", "BWK");
        __ERC20Burnable_init();
        __Pausable_init();
        __Ownable2Step_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(MAX_SUPPLY > 0, "Biawak: Supply must be greater than zero");

        // Mint full supply to the owner's wallet (Feature #1)
        _mint(initialOwner, MAX_SUPPLY); 
        
        // Owner Token Timelock (Feature #5)
        ownerUnlockTime = _ownerUnlockTime;
        emit OwnershipLockSet(_ownerUnlockTime);

        // Set initial special addresses
        liquidityPair = _liquidityPair;
        isFeeExempt[initialOwner] = true;
        isFeeExempt[TREASURY_WALLET] = true;
        isFeeExempt[SPECIAL_WALLET] = true;
        isFeeExempt[address(this)] = true;
        isFeeExempt[address(0)] = true;

        // Set initial strict launch configuration (Feature #22)
        setAntiBotPeriod(3 days);
        // TxFee=1.00%, BuyFee=10.00%, SellFee=10.00%
        setFees(100, 1000, 1000); 
        // 5% Treasury, 3% Reflection, 2% Liquidity, 0% Burn (out of the 10% base fee)
        setFeeAllocation(500, 300, 200, 0); 
        // 1% Max Tx, 0.5% Max Sell, 60s Cooldown
        setMaxLimits(MAX_SUPPLY / 100, MAX_SUPPLY / 200, 60); 
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
        // --- SECURITY AND LOCK CHECKS ---
        require(!isBlacklisted[from] && !isBlacklisted[to], "Biawak: Wallet is blacklisted."); // Feature #15

        // Owner Timelock (Feature #5) - Only allows transactions that don't move owner tokens out of custody
        if (from == owner() && block.timestamp < ownerUnlockTime) {
            // Allows transfer only if the destination is a black hole or the contract itself (e.g., for burning/auto-liquidity)
            require(to == address(0) || to == address(this), "Biawak: Owner tokens are time-locked until unlock time.");
        }

        // Individual Vesting Lock (Feature #6)
        if (block.timestamp < vestingLockUntil[from]) {
            // Allows transfer only if the destination is a black hole or the contract itself
            require(to == address(0) || to == address(this), "Biawak: Wallet is vesting locked.");
        }

        // --- ANTI-WHALE/COOLDOWN/LIMITS (Features #7, #10, #11) ---
        if (from != owner() && to != owner() && from != address(this) && to != address(this)) {
            // Anti-Whale Check (Max Tx)
            if (maxTransactionAmount > 0) {
                require(amount <= maxTransactionAmount, "Biawak: Transfer exceeds max transaction limit (anti-whale).");
            }

            // Max Sell Check (Applies when selling to LP)
            if (to == liquidityPair && maxSellAmount > 0) {
                require(amount <= maxSellAmount, "Biawak: Sell exceeds max sell amount.");
            }

            // Cooldown Check
            if (cooldownTimeSeconds > 0) {
                if (lastTransactionTime[from] > 0) {
                    require(block.timestamp >= lastTransactionTime[from].add(cooldownTimeSeconds), "Biawak: Cooldown period active between transactions.");
                }
                lastTransactionTime[from] = block.timestamp;
            }
        }

        // --- ANTI-BOT/ANTI-SNIPE (Feature #9) ---
        if (antiBotActive && block.timestamp < antiBotPeriodEnd) {
            // During launch, prevent transfers from non-owner/non-special wallets if it's not a transaction with the LP
            if (from != owner() && to != owner() && from != SPECIAL_WALLET && to != SPECIAL_WALLET) {
                require(from == liquidityPair || to == liquidityPair, "Biawak: Anti-bot is active. Only LP interactions allowed.");
            }
        }

        // --- FEE CALCULATION (Features #3, #13, #14) ---
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
        }

        if (feeBps > 0) {
            uint256 totalFee = amount.mul(feeBps).div(10000);
            uint256 amountAfterFee = amount.sub(totalFee);

            // Allocation calculation (Ratios are calculated based on the total charged fee)
            uint256 treasuryAmount = totalFee.mul(treasuryAllocationBps).div(feeBps);
            uint256 reflectionAmount = totalFee.mul(rewardAllocationBps).div(feeBps);
            uint256 liquidityAmount = totalFee.mul(liquidityAllocationBps).div(feeBps);
            uint256 burnAmount = totalFee.mul(burnAllocationBps).div(feeBps);
            
            // Check that the sum of allocated amounts equals the total fee charged
            require(treasuryAmount.add(reflectionAmount).add(liquidityAmount).add(burnAmount) == totalFee, "Biawak: Fee allocation calculation error.");

            // 1. Treasury transfer (Tax)
            super._transfer(from, TREASURY_WALLET, treasuryAmount);

            // 2. Reflection (Reward) - Sent to contract balance
            super._transfer(from, address(this), reflectionAmount); 
            emit RewardDistributed(reflectionAmount);

            // 3. Liquidity/Burn Collection - Held by contract for manual action
            uint256 collectedForLPAndBurn = liquidityAmount.add(burnAmount);
            super._transfer(from, address(this), collectedForLPAndBurn);
            totalLiquidityTokensCollected = totalLiquidityTokensCollected.add(liquidityAmount);
            totalBurnTokensCollected = totalBurnTokensCollected.add(burnAmount);

            emit FeeTaken(from, to, amount, totalFee, liquidityAmount, reflectionAmount, burnAmount);

            // Final transfer of net amount
            super._transfer(from, to, amountAfterFee);
        } else {
            // No fee, standard transfer (Feature #2 applies here)
            super._transfer(from, to, amount);
        }
    }

    // --- ADMIN & GOVERNANCE FUNCTIONS (Owner-only) ---

    // Feature #1: Full administrative control & #3, #22
    function setFees(uint256 _transferFeeBps, uint256 _buyFeeBps, uint256 _sellFeeBps) public onlyAdmin {
        require(_transferFeeBps <= MAX_FEE && _buyFeeBps <= MAX_FEE && _sellFeeBps <= MAX_FEE, "Biawak: Fee exceeds max limit (10%).");
        transferFeeBps = _transferFeeBps;
        buyFeeBps = _buyFeeBps;
        sellFeeBps = _sellFeeBps;
    }

    // Adjusts fee allocation ratios
    function setFeeAllocation(uint256 _treasuryBps, uint256 _rewardBps, uint256 _liquidityBps, uint256 _burnBps) public onlyAdmin {
        // Validation of total allocation is performed within the _transfer logic.
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

    // Feature #15 (Blacklist / Freeze)
    function setBlacklisted(address wallet, bool isBlacklisted_) public onlyAdmin {
        isBlacklisted[wallet] = isBlacklisted_;
        emit FreezeWallet(wallet, isBlacklisted_);
    }

    // Feature #2 (Special wallet fee exemption)
    function setFeeExempt(address wallet, bool isExempt) public onlyAdmin {
        isFeeExempt[wallet] = isExempt;
    }

    // Feature #4 (Minting)
    function mint(address to, uint256 amount) public onlyAdmin {
        require(totalSupply().add(amount) <= MAX_SUPPLY, "Biawak: Minting exceeds max supply.");
        _mint(to, amount);
    }

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
    
    // Feature #14 (Manual Auto-Liquidity mechanism) - Allows owner to withdraw collected tokens
    function withdrawCollectedLiquidityTokens(uint256 amount) public onlyAdmin nonReentrant {
        // Owner calls this to manually pair collected tokens with ETH/BNB to add liquidity.
        require(totalLiquidityTokensCollected >= amount, "Biawak: Amount exceeds collected liquidity tokens.");
        totalLiquidityTokensCollected = totalLiquidityTokensCollected.sub(amount);
        super._transfer(address(this), owner(), amount);
        emit LiquidityTokensWithdrawn(amount);
    }
    
    // Feature #3 (Optional Burn Functionality)
    function burnCollectedTokens() public onlyAdmin nonReentrant {
        uint256 amountToBurn = totalBurnTokensCollected;
        require(amountToBurn > 0, "Biawak: No tokens collected for burning.");
        totalBurnTokensCollected = 0;
        _burn(address(this), amountToBurn);
    }
}
