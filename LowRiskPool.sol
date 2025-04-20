// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Import required interfaces
interface ILendingPoolRegistry {
    function getInsuranceFundPercentage() external view returns (uint256);
    function depositToInsuranceFund() external payable;
    function registerLoan(uint256 projectId, uint256 amount, uint8 riskTier) external returns (bool);
    function recordRepayment(uint256 projectId, uint256 amount) external;
    function recordDefault(uint256 projectId, uint256 amount) external returns (uint256);
    function getProjectManager() external view returns (address);
}

interface IProjectManager {
    function createLendingManager(uint256 projectId, uint256 amount, uint256 interestRate) external returns (address);
    function checkProjectLoanEligibility(uint256 projectId) external view returns (bool, address);
    function getProjectEscrowAddress(uint256 projectId) external view returns (address);
}

interface IProjectLendingManager {
    function initializeLoan(uint256 amount, uint256 interestRate, uint256 duration) external;
    function setupRepaymentSchedule(uint256[] calldata amounts, uint256[] calldata deadlines) external;
    function allocateFundsToMilestones(uint256[] calldata milestoneIds, uint256[] calldata amounts, uint8 currency) external;
}

interface IEscrow {
    function depositProjectFunds(uint256 projectId, uint8 currency, uint256 amount) external payable;
}

/**
 * @title LowRiskPool
 * @dev ERC20-based lending pool for low-risk projects (SCORS 9.0-11.0) with non-transferable tokens
 */
contract LowRiskPool is ERC20, ReentrancyGuard {
    // ============================================================
    // Constants and configuration
    // ============================================================
    
    // Risk tier identification
    uint8 public constant RISK_TIER = 1;
    
    // ============================================================
    // State variables
    // ============================================================
    
    // Core contract references
    address public immutable registry;
    address public owner;
    address public operator;
    
    // Fund management
    uint256 private _totalPoolFunds;   // Total value of funds in the pool
    uint256 private _allocatedFunds;   // Funds currently allocated to loans
    uint256 private _availableFunds;   // Funds available for new loans
    
    // Token price tracking (in wei, starts at 1e18 = 1 token per 1 ETH)
    uint256 public tokenPrice = 1e18;
    
    // Risk parameters - Low Risk specific
    uint256 public maxExposurePerProject = 100 ether; // Max 100 ETH per project
    uint256 public maxUtilizationRate = 8500;         // Max 85% of funds can be deployed
    uint256 public dailyOutflowLimit = 250 ether;     // Max 250 ETH outflow per day
    uint256 public maxWalletPercentage = 1500;        // Max 15% of pool per wallet (basis points)
    uint256 public minScorsRequirement = 900;         // Minimum SCORS of 9.0 (basis points)
    uint256 public maxScorsRequirement = 1100;        // Maximum SCORS of 11.0 (basis points)
    uint256 public baseInterestRate = 500;            // 5% base interest rate (basis points)
    uint256 public maxInterestRate = 700;             // 7% maximum interest rate (basis points)
    
    // Security state
    uint256 public lastOutflowReset;
    uint256 public currentDailyOutflow;
    bool public isPaused = false;
    bool public withdrawalsEnabled = true;
    
    // Loan tracking
    struct LoanData {
        uint256 amount;
        uint256 remainingAmount;
        uint256 interestRate;
        uint256 startTime;
        uint256 endTime;
        bool isActive;
        bool isDefaulted;
        address lendingManager;
    }
    
    mapping(uint256 => LoanData) public projectLoans; // projectId => LoanData
    uint256[] public activeProjects;
    
    // Statistics
    uint256 public activeLoanCount;
    uint256 public totalLoansIssued;
    uint256 public totalDefaultAmount;
    
    // ============================================================
    // Events
    // ============================================================
    
    event Deposit(address indexed lender, uint256 amount, uint256 tokens);
    event Withdrawal(address indexed lender, uint256 amount, uint256 tokens);
    event LoanApproved(uint256 indexed projectId, uint256 amount, uint256 interestRate);
    event LoanDisbursed(uint256 indexed projectId, address escrow, uint256 amount);
    event RepaymentReceived(uint256 indexed projectId, uint256 amount);
    event DefaultProcessed(uint256 indexed projectId, uint256 amount, uint256 recovered);
    event TokenPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorUpdated(address indexed operator);
    event ParametersUpdated(string paramType);
    
    // ============================================================
    // Modifiers
    // ============================================================
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    modifier onlyOperator() {
        require(msg.sender == operator || msg.sender == owner, "Only operator can call this function");
        _;
    }
    
    modifier onlyProjectManager() {
        address projectManager = ILendingPoolRegistry(registry).getProjectManager();
        require(msg.sender == projectManager, "Only project manager can call");
        _;
    }
    
    modifier notPaused() {
        require(!isPaused, "Pool is paused");
        _;
    }
    
    modifier whenWithdrawalsEnabled() {
        require(withdrawalsEnabled, "Withdrawals are disabled");
        _;
    }
    
    // ============================================================
    // Constructor and initialization
    // ============================================================
    
    /**
     * @notice Initializes the low risk lending pool with non-transferable ERC20 tokens
     * @param _registry Address of the central registry
     */
    constructor(address _registry) 
        ERC20("Paxmata Low Risk Pool Token", "PAXT-L") 
    {
        require(_registry != address(0), "Invalid registry address");
        registry = _registry;
        owner = msg.sender;
        operator = msg.sender;
        
        // Initialize security state
        lastOutflowReset = block.timestamp;
    }
    
    // ============================================================
    // Admin functions
    // ============================================================
    
    /**
     * @notice Transfers ownership to a new account
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is zero address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
    
    /**
     * @notice Sets the operator address
     * @param newOperator New operator address
     */
    function setOperator(address newOperator) external onlyOwner {
        require(newOperator != address(0), "New operator is zero address");
        operator = newOperator;
        emit OperatorUpdated(newOperator);
    }
    
    /**
     * @notice Updates pool risk parameters
     * @param _maxExposure Maximum exposure per project
     * @param _maxUtilization Maximum utilization rate (basis points)
     * @param _dailyLimit Daily outflow limit
     * @param _maxWalletPct Maximum percentage per wallet (basis points)
     */
    function updateRiskParameters(
        uint256 _maxExposure,
        uint256 _maxUtilization,
        uint256 _dailyLimit,
        uint256 _maxWalletPct
    ) external onlyOwner {
        require(_maxUtilization <= 9500, "Utilization too high"); // Max 95%
        require(_maxWalletPct <= 5000, "Wallet cap too high"); // Max 50%
        
        maxExposurePerProject = _maxExposure;
        maxUtilizationRate = _maxUtilization;
        dailyOutflowLimit = _dailyLimit;
        maxWalletPercentage = _maxWalletPct;
        
        emit ParametersUpdated("RiskParameters");
    }
    
    /**
     * @notice Updates SCORS requirements and interest rates
     * @param _minScors Minimum SCORS (basis points)
     * @param _maxScors Maximum SCORS (basis points)
     * @param _baseRate Base interest rate (basis points)
     * @param _maxRate Maximum interest rate (basis points)
     */
    function updateRatesAndRequirements(
        uint256 _minScors,
        uint256 _maxScors,
        uint256 _baseRate,
        uint256 _maxRate
    ) external onlyOwner {
        require(_minScors < _maxScors, "Invalid SCORS range");
        require(_baseRate < _maxRate, "Invalid rate range");
        
        minScorsRequirement = _minScors;
        maxScorsRequirement = _maxScors;
        baseInterestRate = _baseRate;
        maxInterestRate = _maxRate;
        
        emit ParametersUpdated("RatesAndRequirements");
    }
    
    /**
     * @notice Pauses or unpauses the pool
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyOperator {
        isPaused = _paused;
        emit ParametersUpdated("PauseState");
    }
    
    /**
     * @notice Enables or disables withdrawals
     * @param _enabled New withdrawals state
     */
    function setWithdrawalsEnabled(bool _enabled) external onlyOperator {
        withdrawalsEnabled = _enabled;
        emit ParametersUpdated("WithdrawalsState");
    }
    
    /**
     * @notice Emergency function to handle stuck funds
     * @param _recipient Recipient address
     * @param _amount Amount to recover
     */
    function emergencyFundRecovery(address _recipient, uint256 _amount) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        require(_amount <= address(this).balance, "Amount exceeds balance");
        require(_amount <= _availableFunds, "Amount exceeds available funds");
        
        _availableFunds -= _amount;
        _totalPoolFunds -= _amount;
        
        (bool success, ) = _recipient.call{value: _amount}("");
        require(success, "Transfer failed");
    }
    
    // ============================================================
    // Lender functions
    // ============================================================
    
    /**
     * @notice Deposit funds into the pool and receive pool tokens
     */
    function deposit() external payable nonReentrant notPaused {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        
        // Calculate insurance fund contribution
        uint256 insurancePercentage = ILendingPoolRegistry(registry).getInsuranceFundPercentage();
        uint256 insuranceContribution = (msg.value * insurancePercentage) / 10000;
        uint256 depositAmount = msg.value - insuranceContribution;
        
        // Calculate tokens to mint for whale protection check
        uint256 tokensForMinting = (depositAmount * 1e18) / tokenPrice;
        
        // Whale protection - check max percentage per wallet
        if (totalSupply() > 0) {
            uint256 newBalance = balanceOf(msg.sender) + tokensForMinting;
            uint256 newPercentage = (newBalance * 10000) / (totalSupply() + tokensForMinting);
            require(newPercentage <= maxWalletPercentage, "Deposit would exceed maximum wallet percentage");
        }
        
        // Contribute to insurance fund
        (bool success, ) = registry.call{value: insuranceContribution}(
            abi.encodeWithSignature("depositToInsuranceFund()")
        );
        require(success, "Insurance fund contribution failed");
        
        // Update pool funds
        _totalPoolFunds += depositAmount;
        _availableFunds += depositAmount;
        
        // Mint tokens to lender (using ERC20 _mint)
        _mint(msg.sender, tokensForMinting);
        
        emit Deposit(msg.sender, depositAmount, tokensForMinting);
    }
    
    /**
     * @notice Withdraw funds from the pool by redeeming pool tokens
     * @param _tokenAmount Amount of pool tokens to redeem
     */
    function withdraw(uint256 _tokenAmount) external nonReentrant whenWithdrawalsEnabled {
        require(_tokenAmount > 0, "Withdrawal amount must be greater than 0");
        require(balanceOf(msg.sender) >= _tokenAmount, "Insufficient tokens");
        
        // Calculate ETH amount
        uint256 ethAmount = (_tokenAmount * tokenPrice) / 1e18;
        
        // Verify sufficient available funds
        require(ethAmount <= _availableFunds, "Insufficient available funds");
        
        // Update pool funds
        _totalPoolFunds -= ethAmount;
        _availableFunds -= ethAmount;
        
        // Burn tokens (using ERC20 _burn)
        _burn(msg.sender, _tokenAmount);
        
        // Send ETH to lender
        (bool success, ) = msg.sender.call{value: ethAmount}("");
        require(success, "ETH transfer failed");
        
        emit Withdrawal(msg.sender, ethAmount, _tokenAmount);
    }
    
    // ============================================================
    // ERC20 Override to make tokens non-transferable
    // ============================================================
    
    /**
     * @notice Override to make tokens non-transferable
     * @dev Only the pool contract can transfer tokens (for minting/burning)
     */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        require(
            sender == address(this) || recipient == address(this),
            "PAXT-L tokens are non-transferable"
        );
        super._transfer(sender, recipient, amount);
    }
    
    /**
     * @notice Override to prevent approvals
     */
    function approve(address /* spender */, uint256 /* amount */) public pure override returns (bool) {
        revert("PAXT-L tokens cannot be approved for spending");
    }
    
    /**
     * @notice Override to prevent transferFrom
     */
    function transferFrom(address /* sender */, address /* recipient */, uint256 /* amount */) public pure override returns (bool) {
        revert("PAXT-L tokens are non-transferable");
    }
    
    // ============================================================
    // Loan application and processing
    // ============================================================
    
    /**
     * @notice User-facing function to apply for a loan
     * @param _projectId ID of the project 
     * @param _amount Requested loan amount
     * @param _userScors User's SCORS rating (in basis points)
     */
    function userApplyForLoan(
        uint256 _projectId,
        uint256 _amount,
        uint256 _userScors
    ) external nonReentrant notPaused {
        // 1. FIRST CHECK - SCORS Eligibility 
        require(_userScors >= minScorsRequirement, "SCORS too low for Low Risk pool");
        require(_userScors <= maxScorsRequirement, "SCORS too high for Low Risk pool");
        
        // 2. Check loan amount is within limits
        require(_amount <= maxExposurePerProject, "Loan amount exceeds maximum exposure");
        require(_amount <= _availableFunds, "Insufficient available funds");
        
        // 3. Check utilization rate
        uint256 newUtilization = ((_allocatedFunds + _amount) * 10000) / _totalPoolFunds;
        require(newUtilization <= maxUtilizationRate, "Utilization rate would be exceeded");
        
        // 4. Check daily outflow limit
        require(currentDailyOutflow + _amount <= dailyOutflowLimit, "Daily outflow limit would be exceeded");
        
        // 5. Get ProjectManager to validate project eligibility
        address projectManagerAddr = ILendingPoolRegistry(registry).getProjectManager();
        (bool eligible, address projectOwner) = IProjectManager(projectManagerAddr).checkProjectLoanEligibility(_projectId);
        require(eligible, "Project not eligible for lending");
        
        // 6. Check that msg.sender is the project owner
        require(msg.sender == projectOwner, "Only project owner can apply for loan");
        
        // 7. Calculate interest rate
        uint256 interestRate = calculateInterestRate(_userScors);
        
        // 8. Process loan internally
        _processLoanApplication(_projectId, _amount, projectOwner, _userScors, interestRate);
    }
    
/**
 * @notice Internal function to process a loan after validation
 * @dev Handles the actual loan processing logic and automatic disbursement
 */
function _processLoanApplication(
    uint256 _projectId,
    uint256 _amount,
    address,
    uint256,
    uint256 _interestRate
) internal returns (bool) {
    // Handle daily outflow reset if needed
    if (block.timestamp >= lastOutflowReset + 1 days) {
        lastOutflowReset = block.timestamp;
        currentDailyOutflow = 0;
    }
    
    // Create temporary loan record
    projectLoans[_projectId] = LoanData({
        amount: _amount,
        remainingAmount: _amount,
        interestRate: _interestRate,
        startTime: block.timestamp,
        endTime: block.timestamp + 365 days, // Default to 1 year loan term
        isActive: true,
        isDefaulted: false,
        lendingManager: address(0) // Will be set later
    });
    
    // Update pool state
    _allocatedFunds += _amount;
    _availableFunds -= _amount;
    activeProjects.push(_projectId);
    activeLoanCount++;
    totalLoansIssued++;
    
    // Track daily outflow
    currentDailyOutflow += _amount;
    
    // Create lending manager via project manager
    address projectManagerAddr = ILendingPoolRegistry(registry).getProjectManager();
    address lendingManager = IProjectManager(projectManagerAddr).createLendingManager(
        _projectId,
        _amount,
        _interestRate
    );

    // Update loan record with lending manager address
    projectLoans[_projectId].lendingManager = lendingManager;
    
    // Get the project's escrow address and disburse funds automatically
    address escrowAddress = IProjectManager(projectManagerAddr).getProjectEscrowAddress(_projectId);
    if (escrowAddress != address(0)) {
        // Internal function to disburse funds without modifier restrictions
        _disburseLoanInternal(_projectId, escrowAddress);
    }
    
    // Update registry
    ILendingPoolRegistry(registry).registerLoan(_projectId, _amount, RISK_TIER);
    
    emit LoanApproved(_projectId, _amount, _interestRate);
    
    return true;
}

/**
 * @notice Process a loan application from a project
 * @param _projectId ID of the project
 * @param _amount Requested loan amount
 * @param _projectOwner Address of the project owner
 * @param _projectScors SCORS rating of the project (in basis points)
 * @return approved Whether the loan was approved
 * @return interestRate The interest rate if approved
 */
function processLoanApplication(
    uint256 _projectId,
    uint256 _amount,
    address _projectOwner,
    uint256 _projectScors
) external nonReentrant onlyProjectManager notPaused returns (bool approved, uint256 interestRate) {
    // SCORS Eligibility Check
    require(_projectScors >= minScorsRequirement, "SCORS too low for this risk pool");
    require(_projectScors <= maxScorsRequirement, "SCORS too high for this risk pool");
    
    // Verify loan amount is within limits
    require(_amount <= maxExposurePerProject, "Loan amount exceeds maximum exposure");
    require(_amount <= _availableFunds, "Insufficient available funds");
    
    // Verify utilization rate won't be exceeded
    uint256 newUtilization = ((_allocatedFunds + _amount) * 10000) / _totalPoolFunds;
    require(newUtilization <= maxUtilizationRate, "Utilization rate would be exceeded");
    
    // Verify daily outflow limit
    require(currentDailyOutflow + _amount <= dailyOutflowLimit, "Daily outflow limit would be exceeded");
    
    // Calculate interest rate
    interestRate = calculateInterestRate(_projectScors);
    
    // Use internal function to process the loan
    approved = _processLoanApplication(_projectId, _amount, _projectOwner, _projectScors, interestRate);
    
    return (approved, interestRate);
}

/**
 * @notice Internal function to disburse loan funds
 * @param _projectId ID of the project
 * @param _escrowAddress Address of the project's escrow
 */
function _disburseLoanInternal(uint256 _projectId, address _escrowAddress) internal {
    LoanData storage loan = projectLoans[_projectId];
    require(loan.isActive, "Loan not active");
    require(_escrowAddress != address(0), "Invalid escrow address");
    
    // Transfer funds to escrow
    uint256 amount = loan.amount;
    (bool success, ) = _escrowAddress.call{value: amount}(
        abi.encodeWithSignature("depositProjectFunds(uint256,uint8,uint256)", _projectId, 0, amount)
    );
    require(success, "Fund transfer to escrow failed");
    
    emit LoanDisbursed(_projectId, _escrowAddress, amount);
}
    
    /**
     * @notice Calculate interest rate based on SCORS (Low Risk specific)
     * @param _scors SCORS rating in basis points
     * @return Interest rate in basis points
     */
    function calculateInterestRate(uint256 _scors) internal view returns (uint256) {
        // At SCORS 11 (1100): minimum rate of 5% (500 basis points)
        // At SCORS 9 (900): maximum rate of 7% (700 basis points)
        if (_scors >= 1100) return baseInterestRate; // Minimum rate for perfect score
        
        // Linear interpolation between min and max rates
        uint256 scoreRange = 1100 - minScorsRequirement; // Range from min acceptable to perfect
        uint256 rateRange = maxInterestRate - baseInterestRate;
        uint256 scoreFromTop = 1100 - _scors;
        
        return baseInterestRate + ((scoreFromTop * rateRange) / scoreRange);
    }
    
    /**
     * @notice Disburse approved loan funds to project escrow
     * @param _projectId ID of the project
     * @param _escrowAddress Address of the project's escrow contract
     */
    function disburseLoan(
        uint256 _projectId,
        address _escrowAddress
    ) external nonReentrant onlyProjectManager {
        LoanData storage loan = projectLoans[_projectId];
        require(loan.isActive, "Loan not active");
        require(_escrowAddress != address(0), "Invalid escrow address");
        
        // Transfer funds to escrow
        uint256 amount = loan.amount;
        (bool success, ) = _escrowAddress.call{value: amount}(
            abi.encodeWithSignature("depositProjectFunds(uint256,uint8,uint256)", _projectId, 0, amount)
        );
        require(success, "Fund transfer to escrow failed");
        
        emit LoanDisbursed(_projectId, _escrowAddress, amount);
    }
    
    // ============================================================
    // Repayment and default handling
    // ============================================================
    
    /**
     * @notice Process a repayment for a loan
     * @param _projectId ID of the project
     */
    function processRepayment(uint256 _projectId) external payable nonReentrant {
        LoanData storage loan = projectLoans[_projectId];
        require(loan.isActive, "Loan not active");
        require(msg.value > 0, "Repayment amount must be greater than 0");
        
        // Update loan remaining amount
        if (msg.value >= loan.remainingAmount) {
            uint256 excess = msg.value - loan.remainingAmount;
            loan.remainingAmount = 0;
            loan.isActive = false;
            
            // Remove from active projects
            _removeFromActiveProjects(_projectId);
            activeLoanCount--;
            
            // Return excess payment if any
            if (excess > 0) {
                (bool success, ) = msg.sender.call{value: excess}("");
                require(success, "Excess return failed");
            }
        } else {
            loan.remainingAmount -= msg.value;
        }
        
        // Update pool statistics
        uint256 actualPayment = msg.value < loan.remainingAmount ? msg.value : loan.remainingAmount;
        _allocatedFunds -= actualPayment;
        _availableFunds += actualPayment;
        
        // Update token price based on interest earned
        _updateTokenPrice();
        
        // Notify registry of repayment
        ILendingPoolRegistry(registry).recordRepayment(_projectId, msg.value);
        
        emit RepaymentReceived(_projectId, msg.value);
    }
    
    /**
     * @notice Process a loan default
     * @param _projectId ID of the project
     */
    function processDefault(uint256 _projectId) external nonReentrant onlyOperator {
        LoanData storage loan = projectLoans[_projectId];
        require(loan.isActive, "Loan not active");
        
        // Mark loan as defaulted
        loan.isActive = false;
        loan.isDefaulted = true;
        
        // Update pool state
        uint256 defaultedAmount = loan.remainingAmount;
        _allocatedFunds -= defaultedAmount;
        totalDefaultAmount += defaultedAmount;
        
        // Remove from active projects
        _removeFromActiveProjects(_projectId);
        activeLoanCount--;
        
        // Claim insurance coverage
        uint256 recoveredAmount = ILendingPoolRegistry(registry).recordDefault(_projectId, defaultedAmount);
        
        // Add recovered amount to available funds
        if (recoveredAmount > 0) {
            _availableFunds += recoveredAmount;
        }
        
        // Update token price based on loss
        _updateTokenPrice();
        
        emit DefaultProcessed(_projectId, defaultedAmount, recoveredAmount);
    }
    
    /**
     * @notice Update the token price based on pool performance
     */
    function _updateTokenPrice() internal {
        uint256 oldPrice = tokenPrice;
        
        // If no tokens have been minted yet, maintain initial price
        if (totalSupply() == 0) {
            return;
        }
        
        // Calculate new token price based on total value and supply
        uint256 totalValue = _totalPoolFunds; // Available + allocated funds
        uint256 newPrice = (totalValue * 1e18) / totalSupply();
        
        tokenPrice = newPrice;
        emit TokenPriceUpdated(oldPrice, newPrice);
    }
    
    /**
     * @notice Remove a project from the active projects array
     * @param _projectId ID of the project to remove
     */
    function _removeFromActiveProjects(uint256 _projectId) internal {
        for (uint256 i = 0; i < activeProjects.length; i++) {
            if (activeProjects[i] == _projectId) {
                // Replace with the last element and pop
                activeProjects[i] = activeProjects[activeProjects.length - 1];
                activeProjects.pop();
                break;
            }
        }
    }
    
    // ============================================================
    // View functions
    // ============================================================
    
    /**
     * @notice Get pool statistics
     * @return tvl Total value locked
     * @return utilized Percentage utilized (basis points)
     * @return activeLoans Number of active loans
     * @return currentPrice Current token price
     */
    function getPoolStats() external view returns (
        uint256 tvl,
        uint256 utilized,
        uint256 activeLoans,
        uint256 currentPrice
    ) {
        tvl = _totalPoolFunds;
        utilized = _totalPoolFunds > 0 ? (_allocatedFunds * 10000) / _totalPoolFunds : 0;
        activeLoans = activeLoanCount;
        currentPrice = tokenPrice;
        
        return (tvl, utilized, activeLoans, currentPrice);
    }
    
    /**
     * @notice Get active project details
     * @return Array of active project IDs
     */
    function getActiveProjects() external view returns (uint256[] memory) {
        return activeProjects;
    }
    
    /**
     * @notice Get loan details for a project
     * @param _projectId ID of the project
     */
    function getLoanDetails(uint256 _projectId) external view returns (
        uint256 amount,
        uint256 remainingAmount,
        uint256 interestRate,
        uint256 startTime,
        uint256 endTime,
        bool isActive,
        bool isDefaulted,
        address lendingManager
    ) {
        LoanData storage loan = projectLoans[_projectId];
        return (
            loan.amount,
            loan.remainingAmount,
            loan.interestRate,
            loan.startTime,
            loan.endTime,
            loan.isActive,
            loan.isDefaulted,
            loan.lendingManager
        );
    }
    
    /**
     * @notice Get ETH value of pool tokens
     * @param _tokenAmount Amount of tokens to check
     * @return ETH value of tokens
     */
    function getTokenValue(uint256 _tokenAmount) external view returns (uint256) {
        return (_tokenAmount * tokenPrice) / 1e18;
    }
    
    /**
     * @notice Check if a project's SCORS meets this pool's requirements
     * @param _scors SCORS rating in basis points
     * @return eligible Whether the SCORS is eligible for this pool
     */
    function isScorsEligible(uint256 _scors) external view returns (bool eligible) {
        return _scors >= minScorsRequirement && _scors <= maxScorsRequirement;
    }
    
    /**
     * @notice Get a user's percentage of the pool
     * @param _user Address to check
     * @return percentage User's percentage of the pool (in basis points)
     */
    function getUserPoolPercentage(address _user) external view returns (uint256 percentage) {
        if (totalSupply() == 0) return 0;
        return (balanceOf(_user) * 10000) / totalSupply();
    }
    
    // Allow the contract to receive ETH
    receive() external payable {}
}
