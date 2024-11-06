// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.3.2/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.3.2/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract FinchStaking is Ownable, ReentrancyGuard {
    IERC20 public finchToken;

    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 lastRewardClaim;
    }

    uint256 public weeklyAPR = 500;
    uint256 public monthlyAPR = 2000;
    uint256 public yearlyAPR = 15000;
    uint256 public penaltyRate = 10;

    uint256 public penaltyPool;
    bool public isPaused = false;
    uint256 public totalStaked;

    mapping(address => mapping(uint256 => Stake)) public stakes;
    mapping(address => uint256) public penaltiesCollected;

    event Staked(address indexed user, uint256 amount, uint256 lockPeriod, uint256 apr);
    event Unstaked(address indexed user, uint256 amount, uint256 penalty);
    event RewardClaimed(address indexed user, uint256 reward);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event APRUpdated(uint256 weeklyAPR, uint256 monthlyAPR, uint256 yearlyAPR);
    event PenaltyRateUpdated(uint256 penaltyRate);
    event Paused();
    event Unpaused();
    event PenaltyReinvested(uint256 amount);

    constructor(IERC20 _finchToken) {
        require(address(_finchToken) != address(0), "Token address cannot be zero");
        finchToken = _finchToken;
    }

    modifier onlyWhenNotPaused() {
        require(!isPaused, "Staking is paused");
        _;
    }

    function setAPRs(uint256 _weeklyAPR, uint256 _monthlyAPR, uint256 _yearlyAPR) external onlyOwner {
        require(_weeklyAPR > 0 && _monthlyAPR > 0 && _yearlyAPR > 0, "APR values must be greater than zero");
        weeklyAPR = _weeklyAPR;
        monthlyAPR = _monthlyAPR;
        yearlyAPR = _yearlyAPR;
        emit APRUpdated(weeklyAPR, monthlyAPR, yearlyAPR);
    }

    function setPenaltyRate(uint256 _penaltyRate) external onlyOwner {
        require(_penaltyRate <= 100, "Penalty rate must be between 0 and 100");
        penaltyRate = _penaltyRate;
        emit PenaltyRateUpdated(penaltyRate);
    }

    function pauseStaking() external onlyOwner {
        isPaused = true;
        emit Paused();
    }

    function unpauseStaking() external onlyOwner {
        isPaused = false;
        emit Unpaused();
    }

    function stake(uint256 amount, uint256 lockPeriod) external nonReentrant onlyWhenNotPaused {
        require(amount > 0, "Cannot stake zero tokens");
        require(
            lockPeriod == 1 weeks || lockPeriod == 4 weeks || lockPeriod == 52 weeks,
            "Invalid lock period"
        );

        uint256 apr = lockPeriod == 1 weeks ? weeklyAPR : lockPeriod == 4 weeks ? monthlyAPR : yearlyAPR;

        Stake storage userStake = stakes[msg.sender][lockPeriod];
        require(userStake.amount == 0, "Already staked for this lock period");

        require(finchToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        stakes[msg.sender][lockPeriod] = Stake({
            amount: amount,
            startTime: block.timestamp,
            lastRewardClaim: block.timestamp
        });
        
        totalStaked += amount;
        emit Staked(msg.sender, amount, lockPeriod, apr);
    }

    function claimReward(uint256 lockPeriod) public nonReentrant onlyWhenNotPaused {
        Stake storage userStake = stakes[msg.sender][lockPeriod];
        require(userStake.amount > 0, "No active stake for this period");

        uint256 reward = calculateReward(msg.sender, lockPeriod);
        require(reward > 0, "No rewards available to claim");

        userStake.lastRewardClaim = block.timestamp;

        require(finchToken.transfer(msg.sender, reward), "Reward transfer failed");
        emit RewardClaimed(msg.sender, reward);
    }

    function calculateReward(address user, uint256 lockPeriod) public view returns (uint256) {
        Stake storage userStake = stakes[user][lockPeriod];
        uint256 apr = lockPeriod == 1 weeks ? weeklyAPR : lockPeriod == 4 weeks ? monthlyAPR : yearlyAPR;
        uint256 duration = block.timestamp - userStake.lastRewardClaim;
        return (userStake.amount * apr * duration) / (10000 * 365 days);
    }

    function unstake(uint256 lockPeriod) external nonReentrant {
        Stake storage userStake = stakes[msg.sender][lockPeriod];
        require(userStake.amount > 0, "No active stake for this period");

        uint256 elapsed = block.timestamp - userStake.startTime;
        uint256 penalty = 0;

        if (elapsed < lockPeriod) {
            penalty = (userStake.amount * penaltyRate) / 100;
            penaltiesCollected[msg.sender] += penalty;
            penaltyPool += penalty;
        }

        uint256 withdrawable = userStake.amount - penalty;
        totalStaked -= userStake.amount;

        delete stakes[msg.sender][lockPeriod];
        
        require(finchToken.transfer(msg.sender, withdrawable), "Unstake transfer failed");
        emit Unstaked(msg.sender, withdrawable, penalty);
    }

    function reinvestPenalties() external nonReentrant onlyOwner {
        totalStaked += penaltyPool;
        emit PenaltyReinvested(penaltyPool);
        penaltyPool = 0;
    }

    function emergencyWithdraw(uint256 lockPeriod) external nonReentrant {
        require(isPaused, "Staking is not paused");

        Stake storage userStake = stakes[msg.sender][lockPeriod];
        require(userStake.amount > 0, "No active stake for this period");

        uint256 amountToWithdraw = userStake.amount;
        totalStaked -= userStake.amount;

        delete stakes[msg.sender][lockPeriod];
        
        require(finchToken.transfer(msg.sender, amountToWithdraw), "Emergency withdraw transfer failed");
        emit EmergencyWithdraw(msg.sender, amountToWithdraw);
    }

    function calculateTotalStaked() external view returns (uint256) {
        return totalStaked;
    }
}
