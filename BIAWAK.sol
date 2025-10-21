
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract BIAWAK is ERC20, Ownable, Pausable {
    uint256 public transferFee = 5;
    uint256 public buyFee = 3;
    uint256 public sellFee = 2;
    bool public burnFee = false;
    address public treasury = 0x095C20E1046805d33c5f1cCe7640F1DD4b693a49;
    address public specialWallet = 0xe0fb20c169d6ee15bb7a55b5f71199099ad4464f;

    uint256 public maxTxAmount;
    uint256 public maxSellPercent = 1;
    uint256 public unlockTime = 1672531200; // 1 Januari 2027
    uint256 public launchTime;        
    uint256 public antiBotDuration = 60; 
    uint256 public txCooldown = 60;  

    mapping(address => uint256) public vestingUnlock;
    mapping(address => bool) public isExchange;
    mapping(address => uint256) public lastTxTime;
    mapping(address => bool) public frozenWallet;

    uint256 public rewardPool;
    mapping(address => uint256) public holderBalanceSnapshot;

    struct StakeInfo { uint256 amount; uint256 timestamp; }
    mapping(address => StakeInfo) public stakes;
    uint256 public stakingRewardRate = 5;

    mapping(address => bool) public voters;
    uint256 public minTokensToVote = 1000 * 10**18;

    event FeeTaken(address indexed from, uint256 amount, string feeType);
    event VestingSet(address indexed account, uint256 unlockTime);
    event SpecialTransfer(address indexed from, address indexed to, uint256 amount);
    event WalletFrozen(address indexed wallet, bool status);
    event RewardDistributed(uint256 totalReward);
    event Stake(address indexed user, uint256 amount);
    event Unstake(address indexed user, uint256 amount);
    event LiquidityAdded(uint256 amount);
    event DynamicFeeChanged(uint256 newTransferFee, uint256 newBuyFee, uint256 newSellFee);

    constructor() ERC20("BIAWAK", "BWK") {
        _mint(msg.sender, 1_000_000_000 * 10**18);
        launchTime = block.timestamp;
    }

    function setSpecialWallet(address _wallet) external onlyOwner { specialWallet = _wallet; }
    function setTreasury(address _treasury) external onlyOwner { treasury = _treasury; }
    function setFees(uint256 _transferFee, uint256 _buyFee, uint256 _sellFee) external onlyOwner {
        transferFee = _transferFee; buyFee = _buyFee; sellFee = _sellFee;
        emit DynamicFeeChanged(_transferFee, _buyFee, _sellFee);
    }
    function setMaxTxAmount(uint256 _maxTxAmount) external onlyOwner { maxTxAmount = _maxTxAmount; }
    function setBurnFee(bool _burnFee) external onlyOwner { burnFee = _burnFee; }

    function setVesting(address account, uint256 _unlockTime) external onlyOwner {
        vestingUnlock[account] = _unlockTime;
        emit VestingSet(account, _unlockTime);
    }
    function setExchange(address account, bool status) external onlyOwner { isExchange[account] = status; }
    function freezeWallet(address account, bool status) external onlyOwner {
        frozenWallet[account] = status;
        emit WalletFrozen(account, status);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }

    function _transfer(address sender, address recipient, uint256 amount) internal override whenNotPaused {
        require(!frozenWallet[sender] && !frozenWallet[recipient], "Wallet frozen");
        require(amount <= maxTxAmount, "Exceeds max tx");
        require(block.timestamp >= lastTxTime[sender] + txCooldown, "Cooldown active");

        lastTxTime[sender] = block.timestamp;

        if(block.timestamp < launchTime + antiBotDuration && sender != owner()) {
            require(amount <= maxTxAmount / 10, "Anti-bot max tx");
        }

        if(sender == owner() && block.timestamp < unlockTime) revert("Owner tokens locked");
        if(vestingUnlock[sender] > 0 && block.timestamp < vestingUnlock[sender]) revert("Wallet vesting active");

        uint256 feeAmount = 0;
        string memory feeType = "";

        if(sender == specialWallet || recipient == specialWallet) {
            feeAmount = 0;
            feeType = "SPECIAL_TRANSFER";
            emit SpecialTransfer(sender, recipient, amount);
        } else if(isExchange[recipient]) {
            uint256 maxSell = totalSupply() * maxSellPercent / 100;
            require(amount <= maxSell, "Exceeds max sell");
            feeAmount = amount * sellFee / 100;
            feeType = "SELL";
        } else if(isExchange[sender]) {
            feeAmount = amount * buyFee / 100;
            feeType = "BUY";
        } else {
            feeAmount = amount * transferFee / 100;
            feeType = "TRANSFER";
        }

        if(feeAmount > 0) {
            uint256 rewardShare = feeAmount / 2;
            uint256 treasuryShare = feeAmount - rewardShare;
            rewardPool += rewardShare;
            if(burnFee) _burn(sender, treasuryShare);
            else super._transfer(sender, treasury, treasuryShare);

            emit FeeTaken(sender, feeAmount, feeType);
        }

        super._transfer(sender, recipient, amount - feeAmount);
    }

    function distributeRewards() external onlyOwner {
        uint256 totalReward = rewardPool;
        rewardPool = 0;
        emit RewardDistributed(totalReward);
    }

    function stake(uint256 amount) external {
        _transfer(msg.sender, treasury, amount);
        stakes[msg.sender].amount += amount;
        stakes[msg.sender].timestamp = block.timestamp;
        emit Stake(msg.sender, amount);
    }

    function unstake() external {
        StakeInfo storage s = stakes[msg.sender];
        require(s.amount > 0, "No stake");
        uint256 reward = s.amount * stakingRewardRate / 100;
        _transfer(treasury, msg.sender, s.amount + reward);
        s.amount = 0;
        emit Unstake(msg.sender, s.amount);
    }

    function addVoter(address account) external onlyOwner {
        require(balanceOf(account) >= minTokensToVote, "Insufficient balance");
        voters[account] = true;
    }
    function removeVoter(address account) external onlyOwner { voters[account] = false; }
}
