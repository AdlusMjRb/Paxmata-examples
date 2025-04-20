// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ILendingPool {
    function processRepayment(uint256 projectId) external payable;
}

/**
 * @title ProjectLendingManager
 * @dev Manages loan repayments and schedules for individual projects
 */
contract ProjectLendingManager is ReentrancyGuard {
    // ============================================================
    // State variables
    // ============================================================
    
    // Core contract references
    uint256 public immutable projectId;
    address public immutable projectOwner;
    address public immutable poolAddress;
    address public immutable projectManager;
    address public immutable escrowAddress;
    
    // Loan details
    struct LoanInfo {
        uint256 amount;
        uint256 interestRate;
        uint256 startDate;
        uint256 endDate;
        bool isActive;
    }
    
    LoanInfo public loan;
    
    // Repayment milestone structure
    struct RepaymentMilestone {
        uint256 id;
        uint256 amount;
        uint256 deadline;
        bool isPaid;
        uint256 paidAmount;
        uint256 paidTime;
    }
    
    mapping(uint256 => RepaymentMilestone) public repaymentMilestones;
    uint256 public milestoneCount;
    
    // ============================================================
    // Events
    // ============================================================
    
    event LoanInitialized(uint256 projectId, uint256 amount, uint256 interestRate, uint256 duration);
    event RepaymentScheduleCreated(uint256 projectId, uint256 milestoneCount);
    event RepaymentMade(uint256 projectId, uint256 milestoneId, uint256 amount, uint256 timestamp);
    event EarlyRepaymentDiscount(uint256 projectId, uint256 milestoneId, uint256 discount);
    event LoanCompleted(uint256 projectId, uint256 timestamp);
    
    // ============================================================
    // Modifiers
    // ============================================================
    
    modifier onlyPool() {
        require(msg.sender == poolAddress, "Only pool can call this function");
        _;
    }
    
    modifier onlyBorrower() {
        require(msg.sender == projectOwner, "Only borrower can call this function");
        _;
    }
    
    // ============================================================
    // Constructor
    // ============================================================
    
    constructor(
        uint256 _projectId,
        address _projectOwner,
        address _poolAddress,
        address _projectManager,
        address _escrowAddress
    ) {
        require(_projectId > 0, "Invalid project ID");
        require(_projectOwner != address(0), "Invalid project owner address");
        require(_poolAddress != address(0), "Invalid pool address");
        require(_projectManager != address(0), "Invalid project manager address");
        require(_escrowAddress != address(0), "Invalid escrow address");
        
        projectId = _projectId;
        projectOwner = _projectOwner;
        poolAddress = _poolAddress;
        projectManager = _projectManager;
        escrowAddress = _escrowAddress;
    }
    
    // ============================================================
    // Initialization functions
    // ============================================================
    
    /**
     * @notice Initialize loan details
     * @param _amount Loan amount
     * @param _interestRate Annual interest rate in basis points
     * @param _duration Loan duration in seconds
     */
    function initializeLoan(
        uint256 _amount,
        uint256 _interestRate,
        uint256 _duration
    ) external onlyPool {
        require(!loan.isActive, "Loan already initialized");
        require(_amount > 0, "Amount must be greater than 0");
        require(_interestRate > 0, "Interest rate must be greater than 0");
        require(_duration > 0, "Duration must be greater than 0");
        
        loan = LoanInfo({
            amount: _amount,
            interestRate: _interestRate,
            startDate: block.timestamp,
            endDate: block.timestamp + _duration,
            isActive: true
        });
        
        emit LoanInitialized(projectId, _amount, _interestRate, _duration);
    }
    
    /**
     * @notice Set up repayment schedule
     * @param _amounts Array of payment amounts
     * @param _deadlines Array of payment deadlines
     */
    function setupRepaymentSchedule(
        uint256[] calldata _amounts,
        uint256[] calldata _deadlines
    ) external onlyPool {
        require(loan.isActive, "Loan not initialized");
        require(milestoneCount == 0, "Schedule already exists");
        require(_amounts.length == _deadlines.length, "Array length mismatch");
        require(_amounts.length > 0, "Empty repayment schedule");
        
        // Create each repayment milestone
        for (uint256 i = 0; i < _amounts.length; i++) {
            milestoneCount++;
            
            repaymentMilestones[milestoneCount] = RepaymentMilestone({
                id: milestoneCount,
                amount: _amounts[i],
                deadline: _deadlines[i],
                isPaid: false,
                paidAmount: 0,
                paidTime: 0
            });
        }
        
        emit RepaymentScheduleCreated(projectId, milestoneCount);
    }
    
    // ============================================================
    // Repayment functions
    // ============================================================
    
    /**
     * @notice Make repayment for a milestone
     * @param _milestoneId ID of the repayment milestone
     */
    function makeRepayment(uint256 _milestoneId) external payable nonReentrant onlyBorrower {
        require(loan.isActive, "Loan not active");
        require(_milestoneId <= milestoneCount, "Invalid milestone ID");
        
        RepaymentMilestone storage milestone = repaymentMilestones[_milestoneId];
        require(!milestone.isPaid, "Already paid");
        
        // Determine payment amount with potential early repayment discount
        uint256 paymentAmount = msg.value;
        uint256 requiredAmount = milestone.amount;
        
        // Apply early repayment discount if applicable
        if (block.timestamp < milestone.deadline) {
            uint256 discountedAmount = calculateEarlyRepaymentDiscount(_milestoneId);
            requiredAmount = discountedAmount;
            
            // Calculate the discount and emit event here instead of in the view function
            uint256 daysEarly = (milestone.deadline - block.timestamp) / 1 days;
            uint256 discountPercent = daysEarly > 100 ? 10 : daysEarly / 10;
            uint256 discount = (milestone.amount * discountPercent) / 100;
            emit EarlyRepaymentDiscount(projectId, _milestoneId, discount);
        }
        
        require(paymentAmount >= requiredAmount, "Insufficient payment");
        
        // Forward payment to pool
        ILendingPool(poolAddress).processRepayment{value: paymentAmount}(projectId);
        
        // Update milestone
        milestone.isPaid = true;
        milestone.paidAmount = paymentAmount;
        milestone.paidTime = block.timestamp;
        
        emit RepaymentMade(projectId, _milestoneId, paymentAmount, block.timestamp);
        
        // Check if all milestones are paid
        checkLoanCompletion();
    }
    
    /**
     * @notice Calculate early repayment discount
     * @param _milestoneId ID of the milestone
     * @return discountedAmount Amount after discount
     */
    function calculateEarlyRepaymentDiscount(uint256 _milestoneId)
        public
        view
        returns (uint256 discountedAmount)
    {
        RepaymentMilestone storage milestone = repaymentMilestones[_milestoneId];
        
        if (block.timestamp >= milestone.deadline) {
            return milestone.amount; // No discount if not early
        }
        
        // Calculate days early
        uint256 daysEarly = (milestone.deadline - block.timestamp) / 1 days;
        
        // Apply discount (0.1% per day early, capped at 10%)
        uint256 discountPercent = daysEarly > 100 ? 10 : daysEarly / 10;
        uint256 discount = (milestone.amount * discountPercent) / 100;
        discountedAmount = milestone.amount - discount;
        
        // Don't emit event in view function
        return discountedAmount;
    }
    
    /**
     * @notice Check if all repayment milestones are completed
     */
    function checkLoanCompletion() internal {
        bool allPaid = true;
        
        for (uint256 i = 1; i <= milestoneCount; i++) {
            if (!repaymentMilestones[i].isPaid) {
                allPaid = false;
                break;
            }
        }
        
        if (allPaid && loan.isActive) {
            loan.isActive = false;
            emit LoanCompleted(projectId, block.timestamp);
        }
    }
    
    // ============================================================
    // View functions
    // ============================================================
    
    /**
     * @notice Get loan details
     * @return amount Total loan amount
     * @return interestRate Annual interest rate in basis points
     * @return startDate Loan start date
     * @return endDate Loan end date
     * @return isActive Whether loan is active
     * @return totalRepaid Total amount repaid
     * @return remainingBalance Remaining balance to repay
     */
    function getLoanDetails() external view returns (
        uint256 amount,
        uint256 interestRate,
        uint256 startDate,
        uint256 endDate,
        bool isActive,
        uint256 totalRepaid,
        uint256 remainingBalance
    ) {
        uint256 totalPaid = 0;
        uint256 totalRequired = 0;
        
        for (uint256 i = 1; i <= milestoneCount; i++) {
            RepaymentMilestone storage milestone = repaymentMilestones[i];
            totalRequired += milestone.amount;
            
            if (milestone.isPaid) {
                totalPaid += milestone.paidAmount;
            }
        }
        
        return (
            loan.amount,
            loan.interestRate,
            loan.startDate,
            loan.endDate,
            loan.isActive,
            totalPaid,
            totalRequired > totalPaid ? totalRequired - totalPaid : 0
        );
    }
    
    /**
     * @notice Get repayment milestone details
     * @param _milestoneId ID of milestone
     * @return amount Payment amount
     * @return deadline Payment due date
     * @return isPaid Whether it's paid
     * @return paidAmount Amount paid (if paid)
     * @return paidTime Time of payment (if paid)
     */
    function getRepaymentMilestone(uint256 _milestoneId) external view returns (
        uint256 amount,
        uint256 deadline,
        bool isPaid,
        uint256 paidAmount,
        uint256 paidTime
    ) {
        require(_milestoneId <= milestoneCount, "Invalid milestone ID");
        
        RepaymentMilestone storage milestone = repaymentMilestones[_milestoneId];
        return (
            milestone.amount,
            milestone.deadline,
            milestone.isPaid,
            milestone.paidAmount,
            milestone.paidTime
        );
    }
    
    /**
     * @notice Get all repayment milestones
     * @return ids Array of milestone IDs
     * @return amounts Array of payment amounts
     * @return deadlines Array of payment deadlines
     * @return isPaid Array of payment statuses
     * @return paidAmounts Array of paid amounts
     * @return paidTimes Array of payment times
     */
    function getAllRepaymentMilestones() external view returns (
        uint256[] memory ids,
        uint256[] memory amounts,
        uint256[] memory deadlines,
        bool[] memory isPaid,
        uint256[] memory paidAmounts,
        uint256[] memory paidTimes
    ) {
        ids = new uint256[](milestoneCount);
        amounts = new uint256[](milestoneCount);
        deadlines = new uint256[](milestoneCount);
        isPaid = new bool[](milestoneCount);
        paidAmounts = new uint256[](milestoneCount);
        paidTimes = new uint256[](milestoneCount);
        
        for (uint256 i = 1; i <= milestoneCount; i++) {
            RepaymentMilestone storage milestone = repaymentMilestones[i];
            
            ids[i-1] = milestone.id;
            amounts[i-1] = milestone.amount;
            deadlines[i-1] = milestone.deadline;
            isPaid[i-1] = milestone.isPaid;
            paidAmounts[i-1] = milestone.paidAmount;
            paidTimes[i-1] = milestone.paidTime;
        }
        
        return (ids, amounts, deadlines, isPaid, paidAmounts, paidTimes);
    }
    
    /**
     * @notice Check if any milestones are overdue
     * @return overdueCount Number of overdue milestones
     * @return isDefaulted Whether loan is in default status
     */
    function checkOverduePayments() external view returns (uint256 overdueCount, bool isDefaulted) {
        if (!loan.isActive) {
            return (0, false);
        }
        
        for (uint256 i = 1; i <= milestoneCount; i++) {
            RepaymentMilestone storage milestone = repaymentMilestones[i];
            
            if (!milestone.isPaid && block.timestamp > milestone.deadline) {
                overdueCount++;
                
                // Check if payment is more than 30 days overdue
                if (block.timestamp > milestone.deadline + 30 days) {
                    isDefaulted = true;
                }
            }
        }
        
        return (overdueCount, isDefaulted);
    }
    
    // Allow the contract to receive ETH
    receive() external payable {}
}
