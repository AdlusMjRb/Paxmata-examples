// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

/**
 * @title LendingPoolRegistry
 * @dev Central coordinator for the P2P lending system, managing relationships between
 * risk-tiered lending pools, tracking statistics, and administering the insurance fund.
 */
contract LendingPoolRegistry {
    // ============================================================
    // State variables
    // ============================================================

    // Pool management
    address public lowRiskPool;
    address public mediumRiskPool;
    address public highRiskPool;
    address public projectManager;
    mapping(address => bool) public authorizedPools;

    // Risk tier definitions (1 = low, 2 = medium, 3 = high)
    mapping(uint8 => uint256) public minScoreRequirement; // Minimum SCORS needed (in basis points, e.g. 900 = 9.0)
    mapping(uint8 => uint256) public maxScoreRequirement; // Maximum SCORS allowed
    mapping(uint8 => uint256) public baseInterestRate; // Interest rate in basis points (e.g. 500 = 5%)
    mapping(uint8 => uint256) public maxInterestRate; // Maximum interest rate

    // Insurance fund
    uint256 public insuranceFundBalance;
    uint256 public insuranceFundPercentage; // In basis points (e.g. 250 = 2.5%)
    mapping(uint8 => uint256) public coverageRate; // e.g. 8000 = 80% coverage

    // System statistics
    uint256 public totalLoansIssued;
    uint256 public totalValueLocked;
    uint256 public totalDefaultsAmount;
    uint256 public activeLoanCount;

    // System control
    address public owner;
    bool public systemPaused;

    // Project loan tracking
    struct LoanInfo {
        uint256 amount;
        uint8 riskTier;
        uint256 issuanceTime;
        bool isActive;
        uint256 defaultAmount;
        address poolAddress;
    }
    
    mapping(uint256 => LoanInfo) public projectLoans;

    // ============================================================
    // Events
    // ============================================================
    
    event PoolsUpdated(address indexed lowRiskPool, address indexed mediumRiskPool, address indexed highRiskPool);
    event LoanRegistered(uint256 indexed projectId, uint256 amount, uint8 riskTier, address pool);
    event RepaymentRecorded(uint256 indexed projectId, uint256 amount);
    event DefaultRecorded(uint256 indexed projectId, uint256 defaultAmount, uint256 coverageAmount);
    event InsuranceClaimed(uint256 indexed projectId, uint256 claimedAmount, uint256 coverageProvided);
    event InsuranceFundContribution(address indexed contributor, uint256 amount);
    event InsuranceFundWithdrawal(address indexed recipient, uint256 amount);
    event SystemStateChanged(bool paused);
    event ParametersUpdated(string parameterType);
    event ProjectManagerSet(address indexed projectManager);

    // ============================================================
    // Modifiers
    // ============================================================
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    modifier onlyAuthorizedPool() {
        require(authorizedPools[msg.sender], "Caller is not an authorized pool");
        _;
    }

    modifier whenNotPaused() {
        require(!systemPaused, "System is paused");
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================
    
    constructor() {
        owner = msg.sender;
        systemPaused = false;
        
        // Set default insurance fund percentage
        insuranceFundPercentage = 250; // 2.5%
        
        // Initialize risk parameters
        
        // Low Risk (Tier 1)
        minScoreRequirement[1] = 900; // 9.0
        maxScoreRequirement[1] = 1100; // 11.0
        baseInterestRate[1] = 500; // 5%
        maxInterestRate[1] = 700; // 7%
        coverageRate[1] = 8000; // 80%
        
        // Medium Risk (Tier 2)
        minScoreRequirement[2] = 700; // 7.0
        maxScoreRequirement[2] = 899; // 8.99
        baseInterestRate[2] = 800; // 8%
        maxInterestRate[2] = 1200; // 12%
        coverageRate[2] = 6000; // 60%
        
        // High Risk (Tier 3)
        minScoreRequirement[3] = 500; // 5.0
        maxScoreRequirement[3] = 699; // 6.99
        baseInterestRate[3] = 1300; // 13%
        maxInterestRate[3] = 1800; // 18%
        coverageRate[3] = 4000; // 40%
    }

    // ============================================================
    // Administrative functions
    // ============================================================
    
    /**
     * @notice Initialize the registry with project manager
     * @param _projectManager Address of the project manager contract
     */
    function initialize(address _projectManager) external onlyOwner {
        require(_projectManager != address(0), "Invalid ProjectManager address");
        projectManager = _projectManager;
        emit ProjectManagerSet(_projectManager);
    }
    
    /**
     * @notice Set addresses for the three risk-tiered lending pools
     * @param _lowRiskPool Address of the low risk pool contract
     * @param _mediumRiskPool Address of the medium risk pool contract
     * @param _highRiskPool Address of the high risk pool contract
     */
    function setPoolAddresses(
        address _lowRiskPool,
        address _mediumRiskPool,
        address _highRiskPool
    ) external onlyOwner {
        require(_lowRiskPool != address(0), "Invalid low risk pool address");
        require(_mediumRiskPool != address(0), "Invalid medium risk pool address");
        require(_highRiskPool != address(0), "Invalid high risk pool address");
        
        // Remove old pool authorizations if they exist
        if (lowRiskPool != address(0)) {
            authorizedPools[lowRiskPool] = false;
        }
        if (mediumRiskPool != address(0)) {
            authorizedPools[mediumRiskPool] = false;
        }
        if (highRiskPool != address(0)) {
            authorizedPools[highRiskPool] = false;
        }
        
        // Set new pool addresses
        lowRiskPool = _lowRiskPool;
        mediumRiskPool = _mediumRiskPool;
        highRiskPool = _highRiskPool;
        
        // Authorize new pools
        authorizedPools[_lowRiskPool] = true;
        authorizedPools[_mediumRiskPool] = true;
        authorizedPools[_highRiskPool] = true;
        
        emit PoolsUpdated(_lowRiskPool, _mediumRiskPool, _highRiskPool);
    }
    
    /**
     * @notice Set the insurance fund contribution percentage
     * @param _percentage Percentage in basis points (e.g. 250 for 2.5%)
     */
    function setInsuranceFundPercentage(uint256 _percentage) external onlyOwner {
        require(_percentage <= 1000, "Percentage too high"); // Maximum 10%
        insuranceFundPercentage = _percentage;
        emit ParametersUpdated("InsuranceFundPercentage");
    }
    
    /**
     * @notice Set the SCORS requirement for a risk tier
     * @param _riskTier Risk tier (1=low, 2=medium, 3=high)
     * @param _minScore Minimum SCORS in basis points (e.g. 900 = 9.0)
     * @param _maxScore Maximum SCORS in basis points
     */
    function setScoreRequirements(
        uint8 _riskTier,
        uint256 _minScore,
        uint256 _maxScore
    ) external onlyOwner {
        require(_riskTier >= 1 && _riskTier <= 3, "Invalid risk tier");
        require(_minScore < _maxScore, "Min score must be less than max score");
        require(_minScore >= 100 && _maxScore <= 1100, "Scores out of range"); // 1.0 to 11.0
        
        minScoreRequirement[_riskTier] = _minScore;
        maxScoreRequirement[_riskTier] = _maxScore;
        
        emit ParametersUpdated("ScoreRequirements");
    }
    
    /**
     * @notice Set the interest rate range for a risk tier
     * @param _riskTier Risk tier (1=low, 2=medium, 3=high)
     * @param _baseRate Base interest rate in basis points (e.g. 500 = 5%)
     * @param _maxRate Maximum interest rate in basis points
     */
    function setInterestRates(
        uint8 _riskTier,
        uint256 _baseRate,
        uint256 _maxRate
    ) external onlyOwner {
        require(_riskTier >= 1 && _riskTier <= 3, "Invalid risk tier");
        require(_baseRate < _maxRate, "Base rate must be less than max rate");
        require(_maxRate <= 3000, "Max rate too high"); // Maximum 30%
        
        baseInterestRate[_riskTier] = _baseRate;
        maxInterestRate[_riskTier] = _maxRate;
        
        emit ParametersUpdated("InterestRates");
    }
    
    /**
     * @notice Set the insurance coverage rate for a risk tier
     * @param _riskTier Risk tier (1=low, 2=medium, 3=high)
     * @param _rate Coverage rate in basis points (e.g. 8000 = 80%)
     */
    function setCoverageRate(uint8 _riskTier, uint256 _rate) external onlyOwner {
        require(_riskTier >= 1 && _riskTier <= 3, "Invalid risk tier");
        require(_rate <= 10000, "Rate out of range"); // Maximum 100%
        
        coverageRate[_riskTier] = _rate;
        
        emit ParametersUpdated("CoverageRate");
    }
    
    /**
     * @notice Pause or unpause the system
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyOwner {
        systemPaused = _paused;
        emit SystemStateChanged(_paused);
    }
    
    /**
     * @notice Withdraw funds from the insurance fund in case of emergency
     * @param _amount Amount to withdraw
     * @param _recipient Recipient address
     */
    function withdrawInsuranceFund(
        uint256 _amount,
        address _recipient
    ) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient address");
        require(_amount <= insuranceFundBalance, "Insufficient insurance fund balance");
        
        insuranceFundBalance -= _amount;
        
        (bool success, ) = _recipient.call{value: _amount}("");
        require(success, "Transfer failed");
        
        emit InsuranceFundWithdrawal(_recipient, _amount);
    }

    // ============================================================
    // Pool management functions
    // ============================================================
    
    /**
     * @notice Register a new loan in the system
     * @param _projectId ID of the project
     * @param _amount Loan amount
     * @param _riskTier Risk tier of the loan
     * @return success Whether the registration was successful
     */
    function registerLoan(
        uint256 _projectId,
        uint256 _amount,
        uint8 _riskTier
    ) external onlyAuthorizedPool whenNotPaused returns (bool success) {
        require(_riskTier >= 1 && _riskTier <= 3, "Invalid risk tier");
        require(_amount > 0, "Loan amount must be greater than 0");
        require(projectLoans[_projectId].poolAddress == address(0), "Loan already registered");
        
        // Update loan record
        projectLoans[_projectId] = LoanInfo({
            amount: _amount,
            riskTier: _riskTier,
            issuanceTime: block.timestamp,
            isActive: true,
            defaultAmount: 0,
            poolAddress: msg.sender
        });
        
        // Update system statistics
        totalLoansIssued++;
        totalValueLocked += _amount;
        activeLoanCount++;
        
        emit LoanRegistered(_projectId, _amount, _riskTier, msg.sender);
        
        return true;
    }
    
    /**
     * @notice Record a loan repayment
     * @param _projectId ID of the project
     * @param _amount Amount repaid
     */
    function recordRepayment(
        uint256 _projectId,
        uint256 _amount
    ) external onlyAuthorizedPool {
        require(projectLoans[_projectId].poolAddress == msg.sender, "Not the loan's pool");
        require(projectLoans[_projectId].isActive, "Loan not active");
        
        emit RepaymentRecorded(_projectId, _amount);
    }
    
    /**
     * @notice Record a loan default
     * @param _projectId ID of the project
     * @param _amount Default amount
     * @return coverageAmount Amount covered by insurance fund
     */
    function recordDefault(
        uint256 _projectId,
        uint256 _amount
    ) external onlyAuthorizedPool returns (uint256 coverageAmount) {
        LoanInfo storage loan = projectLoans[_projectId];
        
        require(loan.poolAddress == msg.sender, "Not the loan's pool");
        require(loan.isActive, "Loan not active");
        
        // Mark loan as defaulted
        loan.isActive = false;
        loan.defaultAmount = _amount;
        
        // Update system statistics
        activeLoanCount--;
        totalDefaultsAmount += _amount;
        
        // Calculate insurance coverage
        uint8 riskTier = loan.riskTier;
        uint256 maxCoverage = (_amount * coverageRate[riskTier]) / 10000;
        
        // Cap coverage by available insurance funds
        coverageAmount = maxCoverage <= insuranceFundBalance ? maxCoverage : insuranceFundBalance;
        
        // Reduce insurance fund balance
        if (coverageAmount > 0) {
            insuranceFundBalance -= coverageAmount;
        }
        
        emit DefaultRecorded(_projectId, _amount, coverageAmount);
        
        return coverageAmount;
    }

    // ============================================================
    // Insurance fund functions
    // ============================================================
    
    /**
     * @notice Deposit funds to the insurance fund
     */
    function depositToInsuranceFund() external payable {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        
        insuranceFundBalance += msg.value;
        
        emit InsuranceFundContribution(msg.sender, msg.value);
    }
    
    /**
     * @notice Claim insurance coverage for a defaulted loan
     * @param _projectId ID of the defaulted project
     * @param _amount Amount of default to cover
     * @return coverageAmount Actual amount covered
     */
    function claimInsuranceCoverage(
        uint256 _projectId,
        uint256 _amount
    ) external onlyAuthorizedPool returns (uint256 coverageAmount) {
        LoanInfo storage loan = projectLoans[_projectId];
        
        require(loan.poolAddress == msg.sender, "Not the loan's pool");
        require(!loan.isActive, "Loan still active");
        require(loan.defaultAmount > 0, "No default recorded");
        
        // Calculate maximum coverage based on risk tier
        uint8 riskTier = loan.riskTier;
        uint256 maxCoverage = (loan.defaultAmount * coverageRate[riskTier]) / 10000;
        maxCoverage = maxCoverage <= _amount ? maxCoverage : _amount;
        
        // Cap coverage by available insurance funds
        coverageAmount = maxCoverage <= insuranceFundBalance ? maxCoverage : insuranceFundBalance;
        
        // Transfer coverage amount
        if (coverageAmount > 0) {
            insuranceFundBalance -= coverageAmount;
            
            (bool success, ) = msg.sender.call{value: coverageAmount}("");
            require(success, "Transfer failed");
        }
        
        emit InsuranceClaimed(_projectId, _amount, coverageAmount);
        
        return coverageAmount;
    }

    // ============================================================
    // View functions
    // ============================================================
    
    /**
     * @notice Get the appropriate pool for a given SCORS
     * @param _score SCORS rating in basis points (e.g. 850 = 8.5)
     * @return pool Address of the appropriate pool
     * @return riskTier Risk tier (1=low, 2=medium, 3=high)
     */
    function getPoolForScore(
        uint256 _score
    ) external view returns (address pool, uint8 riskTier) {
        // Check low risk pool
        if (_score >= minScoreRequirement[1] && _score <= maxScoreRequirement[1]) {
            return (lowRiskPool, 1);
        }
        
        // Check medium risk pool
        if (_score >= minScoreRequirement[2] && _score <= maxScoreRequirement[2]) {
            return (mediumRiskPool, 2);
        }
        
        // Check high risk pool
        if (_score >= minScoreRequirement[3] && _score <= maxScoreRequirement[3]) {
            return (highRiskPool, 3);
        }
        
        // No pool matches the score
        return (address(0), 0);
    }
    
    /**
     * @notice Calculate the interest rate for a given SCORS
     * @param _score SCORS rating in basis points
     * @return interestRate Interest rate in basis points
     */
    function getInterestRateForScore(
        uint256 _score
    ) external view returns (uint256 interestRate) {
        uint8 riskTier = 0;
        
        // Determine risk tier
        if (_score >= minScoreRequirement[1] && _score <= maxScoreRequirement[1]) {
            riskTier = 1;
        } else if (_score >= minScoreRequirement[2] && _score <= maxScoreRequirement[2]) {
            riskTier = 2;
        } else if (_score >= minScoreRequirement[3] && _score <= maxScoreRequirement[3]) {
            riskTier = 3;
        } else {
            return 0; // No matching pool
        }
        
        // Perfect score gets minimum rate for tier
        if (_score >= maxScoreRequirement[riskTier]) {
            return baseInterestRate[riskTier];
        }
        
        // Calculate linearly within the tier
        uint256 scoreRange = maxScoreRequirement[riskTier] - minScoreRequirement[riskTier];
        uint256 rateRange = maxInterestRate[riskTier] - baseInterestRate[riskTier];
        uint256 scoreFromTop = maxScoreRequirement[riskTier] - _score;
        
        // Linear interpolation
        return baseInterestRate[riskTier] + ((scoreFromTop * rateRange) / scoreRange);
    }
    
    /**
     * @notice Get system-wide statistics
     * @return tvl Total value locked
     * @return loansIssued Total loans issued
     * @return activeLoans Active loan count
     * @return defaultAmount Total defaults amount
     * @return insuranceFund Insurance fund balance
     */
    function getSystemStats() external view returns (
        uint256 tvl,
        uint256 loansIssued,
        uint256 activeLoans,
        uint256 defaultAmount,
        uint256 insuranceFund
    ) {
        return (
            totalValueLocked,
            totalLoansIssued,
            activeLoanCount,
            totalDefaultsAmount,
            insuranceFundBalance
        );
    }
    
    /**
     * @notice Calculate potential insurance coverage for a loan amount in a risk tier
     * @param _amount Loan amount
     * @param _riskTier Risk tier
     * @return coverage Maximum coverage amount
     */
    function getLoanCoverage(
        uint256 _amount,
        uint8 _riskTier
    ) external view returns (uint256 coverage) {
        require(_riskTier >= 1 && _riskTier <= 3, "Invalid risk tier");
        
        return (_amount * coverageRate[_riskTier]) / 10000;
    }
    
    /**
     * @notice Get the insurance fund percentage
     * @return Percentage in basis points
     */
    function getInsuranceFundPercentage() external view returns (uint256) {
        return insuranceFundPercentage;
    }
    
    /**
     * @notice Check if an address is a valid pool
     * @param _pool Address to check
     * @return isValid Whether the address is a valid pool
     */
    function isValidPool(address _pool) external view returns (bool) {
        return authorizedPools[_pool];
    }
    
    /**
     * @notice Get the project manager address
     * @return Address of the project manager
     */
    function getProjectManager() external view returns (address) {
        return projectManager;
    }
    
    // Allow the contract to receive ETH for the insurance fund
    receive() external payable {
        insuranceFundBalance += msg.value;
        emit InsuranceFundContribution(msg.sender, msg.value);
    }
}
