// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v5.0/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v5.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v5.0/contracts/security/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v5.0/contracts/proxy/utils/UUPSUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v5.0/contracts/utils/Address.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v5.0/contracts/utils/math/SafeMath.sol";

/**
 * @title BIAWAK (BWK) Token Contract
 * @dev Next-generation DeFi token featuring dynamic fees, anti-bot measures,
 * governance support, vesting, and UUPS upgradeability.
 */
contract BIAWAK is ERC20, Ownable, Pausable, UUPSUpgradeable {
    using SafeMath for uint256;
    using Address for address;

    // --- STRUCTS & CONSTANTS ---

    // Structure for different fee components
    struct TaxRates {
        uint16 treasuryFee; // Allocated to the treasury wallet
        uint16 liquidityFee; // Allocated for auto-liquidity
        uint16 burnFee; // Tokens to be burned
        uint16 rewardFee; // Allocated for reflection/reward system
    }

    // Maximum total fee (e.g., 20.00% or 2000 basis points)
    uint16 private constant MAX_TOTAL_FEE = 2000; 

    // Total supply (1,000,000,000 BWK * 10^18)
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000 * 10**18;

    // Owner token unlock time (1 January 2027, 00:00:00 UTC)
    uint256 public immutable ownerUnlockTime = 1798732800; 

    // --- STATE VARIABLES ---

    // Administrative Wallets
    address public treasuryWallet;
    address public specialWallet; // Fee-free transfer wallet

    // Liquidity Management
    address public uniswapV2Pair;
    address public uniswapV2Router;
    bool public isTradingEnabled = false;

    // Fee Configuration
    TaxRates public buyTax;
    TaxRates public sellTax;
    TaxRates public transferTax;
    
    // Anti-Bot / Anti-Whale Measures
    mapping(address => uint256) public blacklist; // 1 = blacklisted
    mapping(address => uint256) private lastTxTime;
    uint256 public cooldownPeriod = 1 minutes; // Default cooldown
    uint256 public maxTransactionAmount; // Initial Max Tx (1% of supply)
    uint256 public maxSellAmount; // Initial Max Sell (0.5% of supply)
    bool public antiBotLaunchPhase = true;

    // Vesting Schedule (Individual)
    mapping(address => uint256) public vestingUnlockTime;

    // Governance & Snapshot (Simplified for the single contract file)
    mapping(address => uint256) public holderSnapshots;
    
    // Blacklist / Freeze Wallet functionality
    mapping(address => bool) public isFrozen;

    // --- EVENTS ---

    event FeeTaken(address indexed from, address indexed to, uint256 totalFee, uint256 amountAfterFees);
    event SpecialTransfer(address indexed from, address indexed to, uint256 amount);
    event VestingSet(address indexed holder, uint256 unlockTime);
    event FreezeWallet(address indexed wallet, bool frozen);
    event RewardDistributed(uint256 amount, uint256 totalHolders); // Placeholder event
    event LiquidityAdded(uint256 tokenAmount, uint256 ethAmount);
    event DynamicFeeChanged(string indexed typeOfFee, uint16 treasury, uint16 liquidity, uint16 burn, uint16 reward);
    event MaxLimitsUpdated(uint256 newMaxTx, uint256 newMaxSell);
    event CooldownUpdated(uint256 newCooldown);
    event SnapshotDistributed(uint256 totalAmount); // Placeholder for dividend/snapshot distribution
    event TradingEnabled(address indexed pairAddress);


    // --- INITIALIZATION & UPGRADEABILITY ---

    /**
     * @dev Constructor is used to initialize the contract's state before deployment.
     * It sets the total supply and prevents direct function calls.
     */
    constructor() ERC20("BIAWAK", "BWK") Ownable(msg.sender) {
        _disableInitializers();
        // The _mint call is moved to the initializer for UUPS compliance.
    }

    /**
     * @dev Initializer for the UUPS contract. Called only once after deployment.
     * @param _treasuryWallet The address for treasury fee allocation.
     * @param _specialWallet The address for fee-free transfers and price stabilization.
     */
    function initialize(address _treasuryWallet, address _specialWallet) public initializer {
        __ERC20_init("BIAWAK", "BWK");
        __Ownable_init(msg.sender);
        __Pausable_init();
        __UUPSUpgradeable_init();

        require(_treasuryWallet != address(0) && _specialWallet != address(0), "Zero address not allowed");
        
        // Set initial parameters
        treasuryWallet = _treasuryWallet;
        specialWallet = _specialWallet;
        
        // Initial token distribution (100% to owner)
        _mint(msg.sender, TOTAL_SUPPLY);

        // Initial Fees (e.g., 2% Treasury, 1% Burn, 1% Reward, 1% Liquidity)
        // Note: These initial fees are placeholders and can be changed immediately by the owner.
        buyTax = TaxRates({treasuryFee: 100, liquidityFee: 100, burnFee: 50, rewardFee: 50}); // 3.0% total
        sellTax = TaxRates({treasuryFee: 150, liquidityFee: 150, burnFee: 100, rewardFee: 100}); // 5.0% total
        transferTax = TaxRates({treasuryFee: 50, liquidityFee: 0, burnFee: 0, rewardFee: 50}); // 1.0% total

        // Set Anti-Whale limits (1% max tx, 0.5% max sell)
        maxTransactionAmount = TOTAL_SUPPLY.mul(1).div(100);
        maxSellAmount = TOTAL_SUPPLY.mul(5).div(1000); // 0.5%
        
        emit DynamicFeeChanged("Initial Buy", buyTax.treasuryFee, buyTax.liquidityFee, buyTax.burnFee, buyTax.rewardFee);
        emit DynamicFeeChanged("Initial Sell", sellTax.treasuryFee, sellTax.liquidityFee, sellTax.burnFee, sellTax.rewardFee);
        emit DynamicFeeChanged("Initial Transfer", transferTax.treasuryFee, transferTax.liquidityFee, transferTax.burnFee, transferTax.rewardFee);
    }

    /**
     * @dev Required UUPS function to restrict upgrades to the owner.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // --- ADMINISTRATIVE FUNCTIONS (Owner Only) ---

    /**
     * @dev Mints new tokens and sends them to the specified address.
     * @param to The recipient address.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Burns tokens from the specified address.
     * @param from The address to burn from.
     * @param amount The amount of tokens to burn.
     */
    function burnFrom(address from, uint256 amount) public onlyOwner {
        _burn(from, amount);
    }

    /**
     * @dev Toggles the emergency pause state for all transactions.
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Toggles the pause state off.
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Sets a custom vesting unlock time for an individual wallet.
     * @param holder The wallet address to set the vesting for.
     * @param unlockTime Timestamp when tokens become fully transferable.
     */
    function setVesting(address holder, uint256 unlockTime) public onlyOwner {
        vestingUnlockTime[holder] = unlockTime;
        emit VestingSet(holder, unlockTime);
    }

    /**
     * @dev Sets or removes a wallet from the blacklist/freeze list.
     * @param wallet The wallet address.
     * @param freezeStatus True to freeze/blacklist, false to unfreeze/remove.
     */
    function setFreezeWallet(address wallet, bool freezeStatus) public onlyOwner {
        isFrozen[wallet] = freezeStatus;
        emit FreezeWallet(wallet, freezeStatus);
    }

    // --- FEE & LIMIT MANAGEMENT ---

    /**
     * @dev Updates all components of the tax rate for a specific type (Buy/Sell/Transfer).
     * @param typeOfFee 0 for Buy, 1 for Sell, 2 for Transfer.
     * @param treasury The new treasury fee (in basis points, 100 = 1%).
     * @param liquidity The new liquidity fee (in basis points).
     * @param burn The new burn fee (in basis points).
     * @param reward The new reward fee (in basis points).
     */
    function setTax(uint8 typeOfFee, uint16 treasury, uint16 liquidity, uint16 burn, uint16 reward) public onlyOwner {
        uint16 totalFee = treasury.add(liquidity).add(burn).add(reward);
        require(totalFee <= MAX_TOTAL_FEE, "Fee exceeds max allowed (20.00%)");

        TaxRates memory newTax = TaxRates({
            treasuryFee: treasury,
            liquidityFee: liquidity,
            burnFee: burn,
            rewardFee: reward
        });

        if (typeOfFee == 0) {
            buyTax = newTax;
            emit DynamicFeeChanged("Buy", treasury, liquidity, burn, reward);
        } else if (typeOfFee == 1) {
            sellTax = newTax;
            emit DynamicFeeChanged("Sell", treasury, liquidity, burn, reward);
        } else if (typeOfFee == 2) {
            transferTax = newTax;
            emit DynamicFeeChanged("Transfer", treasury, liquidity, burn, reward);
        } else {
            revert("Invalid fee type");
        }
    }

    /**
     * @dev Updates the anti-whale transaction limits.
     */
    function setMaxLimits(uint256 newMaxTx, uint256 newMaxSell) public onlyOwner {
        require(newMaxTx >= TOTAL_SUPPLY.div(1000) && newMaxSell >= TOTAL_SUPPLY.div(2000), "Limits too low"); // Minimum 0.1% and 0.05%
        maxTransactionAmount = newMaxTx;
        maxSellAmount = newMaxSell;
        emit MaxLimitsUpdated(newMaxTx, newMaxSell);
    }

    /**
     * @dev Updates the anti-bot transaction cooldown period.
     */
    function setCooldownPeriod(uint256 newCooldown) public onlyOwner {
        cooldownPeriod = newCooldown;
        emit CooldownUpdated(newCooldown);
    }

    /**
     * @dev Owner calls this function to enable trading and set the liquidity pair/router.
     * This moves the contract out of the strict anti-bot launch phase.
     * @param routerAddress The address of the DEX router (e.g., Uniswap/PancakeSwap).
     * @param pairAddress The address of the newly created liquidity pool pair.
     */
    function enableTrading(address routerAddress, address pairAddress) public onlyOwner {
        require(!isTradingEnabled, "Trading already enabled");
        require(routerAddress != address(0) && pairAddress != address(0), "Zero address not allowed");
        uniswapV2Router = routerAddress;
        uniswapV2Pair = pairAddress;
        isTradingEnabled = true;
        antiBotLaunchPhase = false; // Disable strict initial launch restrictions
        emit TradingEnabled(pairAddress);
    }
    
    // --- GOVERNANCE / SNAPSHOT FUNCTIONS ---

    /**
     * @dev Takes a snapshot of all current holder balances for dividend/governance voting.
     * In a real system, this would iterate through holders, but here it's simplified.
     */
    function takeSnapshot() public onlyOwner {
        // Simple example: taking a snapshot of the owner's balance
        holderSnapshots[owner()] = balanceOf(owner());
        emit SnapshotDistributed(0); // Placeholder
    }

    // --- CORE TRANSFER LOGIC (Overridden) ---

    /**
     * @dev Overridden function to implement all custom tokenomics logic.
     */
    function _transfer(address from, address to, uint256 amount) internal override whenNotPaused {
        require(from != address(0) && to != address(0), "ERC20: transfer from the zero address");
        require(!isFrozen[from], "Transfer blocked: Sender is frozen");
        require(!isFrozen[to], "Transfer blocked: Receiver is frozen");

        // Owner Lockup Check
        if (from == owner() && block.timestamp < ownerUnlockTime) {
            revert("Owner tokens are time-locked until 1 Jan 2027");
        }
        // Vesting Check for Sender
        if (vestingUnlockTime[from] > block.timestamp) {
            revert("Vesting period not yet complete for sender");
        }

        // Determine Transaction Type (Buy/Sell/Transfer)
        bool isLiquiditySwap = from == uniswapV2Pair || to == uniswapV2Pair;
        bool isBuy = isTradingEnabled && to == uniswapV2Pair; // Token from liquidity pair to user
        bool isSell = isTradingEnabled && from == uniswapV2Pair; // Token from user to liquidity pair
        
        TaxRates memory activeTax;

        if (!isTradingEnabled) {
            // Apply high transfer fees/strict limits during initial period
            activeTax = transferTax;
        } else if (isLiquiditySwap) {
            // Check Max Transaction / Max Sell Limits
            if (amount > maxTransactionAmount && (isBuy || isSell)) {
                revert("Transaction amount exceeds max limit");
            }
            if (isSell && amount > maxSellAmount) {
                revert("Sell amount exceeds max sell limit");
            }

            // Anti-bot/Cooldown Check (only for non-liquidity pool transactions)
            if (lastTxTime[from] + cooldownPeriod > block.timestamp && !isBuy) {
                 revert("Cooldown period active. Wait for next transaction.");
            }
            lastTxTime[from] = block.timestamp;

            activeTax = isBuy ? buyTax : sellTax;
        } else {
            // Standard peer-to-peer transfer
            activeTax = transferTax;
        }

        // --- FEE EXEMPTION ---
        if (from == specialWallet || to == specialWallet) {
            super._transfer(from, to, amount);
            emit SpecialTransfer(from, to, amount);
            return;
        }

        // --- FEE CALCULATION & EXECUTION ---

        uint256 totalFeeBps = activeTax.treasuryFee.add(activeTax.liquidityFee).add(activeTax.burnFee).add(activeTax.rewardFee);
        
        if (totalFeeBps > 0) {
            uint256 totalFee = amount.mul(totalFeeBps).div(10000); // 10000 = 100% (basis points)
            uint256 amountAfterFees = amount.sub(totalFee);

            // 1. Send to Treasury
            if (activeTax.treasuryFee > 0) {
                uint256 treasuryAmount = amount.mul(activeTax.treasuryFee).div(10000);
                super._transfer(from, treasuryWallet, treasuryAmount);
            }

            // 2. Send to Liquidity Pool
            if (activeTax.liquidityFee > 0) {
                uint256 liquidityAmount = amount.mul(activeTax.liquidityFee).div(10000);
                super._transfer(from, address(this), liquidityAmount); // Send to contract for auto-liquidity mechanism
                // In a full implementation, the contract would swap a portion of tokens for ETH/Stablecoin
                // and pair them with the remaining tokens to add liquidity automatically.
                emit LiquidityAdded(liquidityAmount, 0); // Placeholder for ETH amount
            }

            // 3. Burn (Reduce Total Supply)
            if (activeTax.burnFee > 0) {
                uint256 burnAmount = amount.mul(activeTax.burnFee).div(10000);
                _burn(from, burnAmount);
            }

            // 4. Reward / Reflection (Handled by the overall fee reduction and distributed later via snapshot/dividend system)
            // The remaining rewardFee portion is implicitly reduced from the sender's balance,
            // and the mechanism for its distribution is handled off-chain or by a separate contract,
            // relying on the Snapshot/Dividend system defined in the events.

            // Final transfer of the net amount
            super._transfer(from, to, amountAfterFees);
            emit FeeTaken(from, to, totalFee, amountAfterFees);
        } else {
            // No Fee
            super._transfer(from, to, amount);
        }
    }
    
    // Fallback function to handle incoming ETH for auto-liquidity
    receive() external payable {}
}
