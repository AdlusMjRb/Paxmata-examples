// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./interfaces/ICurrency.sol";
import "./interfaces/IPaxmataEscrow.sol";

/**
 * @title PaxmataEscrow
 * @dev Handles escrow functionalities for project funds, milestones, and bidding.
 */
contract PaxmataEscrow is IPaxmataEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

        // Define the Bid struct
    struct Bid {
        address bidder;
        uint256 amount;
        ICurrency.Currency currency;
        bool refunded;
        bool selected;
        uint256 timestamp;
    }

    // Define the MilestoneAllocation struct
    struct MilestoneAllocation {
        uint256 amount;
        ICurrency.Currency currency;
        bool allocated;
    }

    // Core state variables
    address public immutable projectManager;
    address public immutable nftContract;
    address public immutable paxmataWallet;

    // Mapping of projectId to registered office contracts
    mapping(uint256 => address) public registeredOffices;

    // Project tracking
    mapping(uint256 => Bid[]) public projectBids; // projectId => array of bids
    mapping(uint256 => address) public projectOwners; // projectId => project owner address
    mapping(uint256 => mapping(ICurrency.Currency => uint256)) public projectEscrowBalances;
    mapping(uint256 => mapping(uint256 => MilestoneAllocation)) public milestoneAllocations;
    mapping(ICurrency.Currency => address) public supportedTokens;
    mapping(uint256 => address) public projectOffices; // Maps projectId to OfficeContract address

    // Constants
    uint256 public constant DEV_BIDDING_FEE = 0.001 ether;

    // Events
    event BidPlaced(
        uint256 indexed projectId,
        address indexed bidder,
        uint256 amount,
        ICurrency.Currency currency,
        uint256 timestamp
    );
    event BidAccepted(
        uint256 indexed projectId,
        address indexed selectedBidder,
        uint256 amount,
        ICurrency.Currency currency
    );
    event BidRefunded(
        uint256 indexed projectId,
        address indexed bidder,
        uint256 amount,
        ICurrency.Currency currency
    );
    event ProjectOwnerRegistered(
        uint256 indexed projectId,
        address indexed owner
    );
    event OfficeRegistered(
        uint256 indexed projectId,
        address indexed officeContract
    );
    event PaymentReleased(
        uint256 indexed projectId,
        address indexed recipient,
        uint256 amount,
        ICurrency.Currency currency
    );
    event ProjectFundsDeposited(
        uint256 indexed projectId,
        address indexed depositor,
        uint256 amount,
        ICurrency.Currency currency
    );
    event CurrencySupported(ICurrency.Currency currency, address tokenAddress);
    event FundsAllocatedToMilestone(
        uint256 indexed projectId,
        uint256 indexed milestoneId,
        uint256 amount,
        ICurrency.Currency currency
    );

    // Custom errors
    error Unauthorized();
    error InvalidAddress();
    error InsufficientBalance();
    error UnsupportedCurrency();
    error AlreadyRegistered();
    error InvalidAmount();
    error ProjectNotRegistered();
    error BidNotFound();
    error TransferFailed();
error AlreadySelected();
error AlreadyRefunded();
error NoBids();
error NFTApprovalFailed();
    /**
     * @dev Modifier to restrict access to only the Project Manager.
     */
    modifier onlyProjectManager() {
        if (msg.sender != projectManager) revert Unauthorized();
        _;
    }

    /**
     * @dev Modifier to restrict access to only the registered OfficeContract for a projectId.
     */
    modifier onlyRegisteredOffice(uint256 projectId) {
        if (msg.sender != registeredOffices[projectId]) revert Unauthorized();
        _;
    }
    

    modifier onlyOfficeContract(uint256 projectId) {
    require(
        projectOffices[projectId] == msg.sender,
        "Caller is not the registered OfficeContract"
    );
    _;
}

    /**
     * @dev Constructor to initialize the Escrow contract.
     */
    constructor(
        address _projectManager,
        address _nftContract,
        address _paxmataWallet
    ) {
        if (
            _projectManager == address(0) ||
            _nftContract == address(0) ||
            _paxmataWallet == address(0)
        ) revert InvalidAddress();

        projectManager = _projectManager;
        nftContract = _nftContract;
        paxmataWallet = _paxmataWallet;

        // Set DEV as supported native currency
        supportedTokens[ICurrency.Currency.DEV] = address(1);
    }

    /**
     * @dev Registers the Office Contract for a specific project.
     */
    function registerProjectOffice(uint256 projectId, address officeContract)
        external
        override
    {
        require(officeContract != address(0), "Invalid OfficeContract address");
        require(registeredOffices[projectId] == address(0), "Office already registered");
        
        // Allow the OfficeContract to register itself
        require(msg.sender == officeContract, "Only OfficeContract can register itself");
        
        registeredOffices[projectId] = officeContract;
        projectOffices[projectId] = officeContract; // Update both mappings
        
        emit OfficeRegistered(projectId, officeContract);
    }

    /**
     * @dev Registers the Project Owner for a given project.
     */
    function registerProjectOwner(uint256 projectId, address owner)
        external
        override
    {
        require(owner != address(0), "Invalid owner address");
        require(projectOwners[projectId] == address(0), "Owner already registered");
        
        // Only allow registered office contract to set the owner
        require(
            msg.sender == registeredOffices[projectId],
            "Only registered office can set owner"
        );
        
        projectOwners[projectId] = owner;
        emit ProjectOwnerRegistered(projectId, owner);
    }

/**
 * @dev Sets the OfficeContract for a given project. Can only be called by ProjectManager.
 */
function setOfficeContract(uint256 projectId, address officeContract)
    external
    onlyProjectManager
{
    if (officeContract == address(0)) revert InvalidAddress();
    if (projectOffices[projectId] != address(0)) revert AlreadyRegistered();

    projectOffices[projectId] = officeContract;
    emit OfficeContractSet(projectId, officeContract);
}

event OfficeContractSet(uint256 indexed projectId, address indexed officeContract);



    /**
     * @dev Combined function to approve and place bid in one transaction.
     */
    function approveAndPlaceBid(
        uint256 projectId,
        uint256 amount,
        ICurrency.Currency currency
    ) external payable nonReentrant {
        if (projectOwners[projectId] == address(0)) revert ProjectNotRegistered();
        if (msg.sender == projectOwners[projectId]) revert("Owner cannot bid");
        if (amount == 0) revert InvalidAmount();

        // Handle native currency (DEV)
        if (currency == ICurrency.Currency.DEV) {
            if (msg.value != amount) revert InvalidAmount();
            if (msg.value < DEV_BIDDING_FEE) revert("Below minimum bid");

            projectEscrowBalances[projectId][currency] += msg.value;
        }
        // Handle ERC20 tokens
        else {
            if (supportedTokens[currency] == address(0)) revert UnsupportedCurrency();

            IERC20 token = IERC20(supportedTokens[currency]);
            token.safeTransferFrom(msg.sender, address(this), amount);
            projectEscrowBalances[projectId][currency] += amount;
        }

        // Record the bid
        projectBids[projectId].push(
            Bid({
                bidder: msg.sender,
                amount: amount,
                currency: currency,
                refunded: false,
                selected: false,
                timestamp: block.timestamp
            })
        );

        emit BidPlaced(
            projectId,
            msg.sender,
            amount,
            currency,
            block.timestamp
        );
    }

/**
 * @dev Accept a bid and handle NFT transfer with automatic approval.
 */
function acceptBidAndTransfer(uint256 projectId, uint256 bidIndex) 
   external 
   nonReentrant 
{
   // Check if bids exist and validate index
   if (projectBids[projectId].length == 0) revert NoBids();
   if (bidIndex >= projectBids[projectId].length) revert BidNotFound();
   if (msg.sender != projectOwners[projectId]) revert Unauthorized();

   // Get and validate bid status 
   Bid storage selectedBid = projectBids[projectId][bidIndex];
   if (selectedBid.selected) revert AlreadySelected();
   if (selectedBid.refunded) revert AlreadyRefunded();

   // Handle NFT approval and transfer
   IERC721 nftContractInstance = IERC721(nftContract);
   address approved = nftContractInstance.getApproved(projectId);
   
   if (approved != address(this)) {
       try nftContractInstance.approve(address(this), projectId) {
       } catch {
           revert NFTApprovalFailed();
       }
   }

   approved = nftContractInstance.getApproved(projectId);
   if (approved != address(this)) revert NFTApprovalFailed();

   selectedBid.selected = true;
   nftContractInstance.safeTransferFrom(msg.sender, selectedBid.bidder, projectId);

   // Handle payment transfer
   if (selectedBid.currency == ICurrency.Currency.DEV) {
       (bool success, ) = paxmataWallet.call{value: selectedBid.amount}("");
       if (!success) revert TransferFailed();
   } else {
       IERC20(supportedTokens[selectedBid.currency]).safeTransfer(
           paxmataWallet,
           selectedBid.amount
       );
   }

   projectEscrowBalances[projectId][selectedBid.currency] -= selectedBid.amount;
   _refundOtherBidders(projectId, bidIndex);

   emit BidAccepted(
       projectId,
       selectedBid.bidder,
       selectedBid.amount,
       selectedBid.currency
   );
}

   /**
     * @dev Internal function to refund other bidders.
     */
    function _refundOtherBidders(uint256 projectId, uint256 winningBidIndex)
        internal
    {
        Bid[] storage bids = projectBids[projectId];
        for (uint256 i = 0; i < bids.length; i++) {
            if (i != winningBidIndex && !bids[i].refunded && !bids[i].selected) {
                bids[i].refunded = true;

                if (bids[i].currency == ICurrency.Currency.DEV) {
                    (bool success, ) = bids[i].bidder.call{value: bids[i].amount}("");
                    if (!success) revert TransferFailed();
                } else {
                    IERC20(supportedTokens[bids[i].currency]).safeTransfer(
                        bids[i].bidder,
                        bids[i].amount
                    );
                }

                projectEscrowBalances[projectId][bids[i].currency] -= bids[i].amount;

                emit BidRefunded(
                    projectId,
                    bids[i].bidder,
                    bids[i].amount,
                    bids[i].currency
                );
            }
        }
    }

    /**
     * @dev Deposits funds for a project.
     */
    function depositProjectFunds(
        uint256 projectId,
        ICurrency.Currency currency,
        uint256 amount
    ) external payable override nonReentrant {
        if (projectOwners[projectId] == address(0)) revert ProjectNotRegistered();
        if (amount == 0) revert InvalidAmount();

        if (currency == ICurrency.Currency.DEV) {
            if (msg.value != amount) revert InvalidAmount();
            projectEscrowBalances[projectId][currency] += msg.value;
        } else {
            if (supportedTokens[currency] == address(0)) revert UnsupportedCurrency();

            IERC20 token = IERC20(supportedTokens[currency]);
            token.safeTransferFrom(msg.sender, address(this), amount);
            projectEscrowBalances[projectId][currency] += amount;
        }

        emit ProjectFundsDeposited(projectId, msg.sender, amount, currency);
    }

    /**
     * @dev Allocates funds to a specific milestone.
     */
    function allocateFundsToMilestone(
        uint256 projectId,
        uint256 milestoneId,
        uint256 amount,
        ICurrency.Currency currency
    ) external override onlyRegisteredOffice(projectId) nonReentrant {
        if (projectEscrowBalances[projectId][currency] < amount)
            revert InsufficientBalance();

        // Update milestone allocation
        MilestoneAllocation storage allocation = milestoneAllocations[projectId][milestoneId];
        allocation.amount += amount;
        allocation.currency = currency;
        allocation.allocated = true;

        // Update project balance
        projectEscrowBalances[projectId][currency] -= amount;

        emit FundsAllocatedToMilestone(projectId, milestoneId, amount, currency);
    }

    /**
     * @dev Releases payment for a milestone.
     */
    function releasePayment(
        uint256 projectId,
        uint256 milestoneId,
        address recipient,
        uint256 amount,
        ICurrency.Currency currency
    ) external override nonReentrant onlyRegisteredOffice(projectId) {
        if (recipient == address(0)) revert InvalidAddress();

        MilestoneAllocation storage allocation = milestoneAllocations[projectId][milestoneId];
        if (!allocation.allocated) revert("Funds not allocated");
        if (allocation.amount < amount) revert InsufficientBalance();
        if (allocation.currency != currency) revert("Currency mismatch");

        // Update allocation
        allocation.amount -= amount;
        if (allocation.amount == 0) {
            allocation.allocated = false;
        }

        // Transfer funds
        if (currency == ICurrency.Currency.DEV) {
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(supportedTokens[currency]).safeTransfer(recipient, amount);
        }

        emit PaymentReleased(projectId, recipient, amount, currency);
    }

    /**
     * @dev Adds support for a new currency.
     */
    function addSupportedCurrency(ICurrency.Currency currency, address tokenAddress)
        external
        onlyProjectManager
    {
        if (currency == ICurrency.Currency.DEV) revert("DEV is native currency");
        if (tokenAddress == address(0)) revert InvalidAddress();
        if (supportedTokens[currency] != address(0)) revert("Already supported");

        supportedTokens[currency] = tokenAddress;
        emit CurrencySupported(currency, tokenAddress);
    }

    /**
     * @dev Get all bids for a project.
     */
    function getProjectBids(uint256 projectId)
        external
        view
        returns (
            address[] memory bidders,
            uint256[] memory amounts,
            ICurrency.Currency[] memory currencies,
            bool[] memory refunded,
            bool[] memory selected,
            uint256[] memory timestamps
        )
    {
        Bid[] storage bids = projectBids[projectId];
        uint256 length = bids.length;

        bidders = new address[](length);
        amounts = new uint256[](length);
        currencies = new ICurrency.Currency[](length);
        refunded = new bool[](length);
        selected = new bool[](length);
        timestamps = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            Bid storage bid = bids[i];
            bidders[i] = bid.bidder;
            amounts[i] = bid.amount;
            currencies[i] = bid.currency;
            refunded[i] = bid.refunded;
            selected[i] = bid.selected;
            timestamps[i] = bid.timestamp;
        }

        return (bidders, amounts, currencies, refunded, selected, timestamps);
    }

    /**
     * @dev Get milestone allocation details.
     */
    function getMilestoneAllocation(uint256 projectId, uint256 milestoneId)
        external
        view
        returns (uint256 amount, ICurrency.Currency currency, bool allocated)
    {
        MilestoneAllocation storage allocation = milestoneAllocations[projectId][milestoneId];
        return (allocation.amount, allocation.currency, allocation.allocated);
    }

    /**
     * @dev Checks if a currency is supported.
     */
    function isSupportedCurrency(ICurrency.Currency currency)
        public
        view
        override
        returns (bool)
    {
        return supportedTokens[currency] != address(0);
    }

    /**
     * @dev Gets the token address for a supported currency.
     */
    function getSupportedTokenAddress(ICurrency.Currency currency)
        external
        view
        override
        returns (address)
    {
        return supportedTokens[currency];
    }

    /**
     * @dev Get project balance for a specific currency.
     */
    function getProjectBalance(uint256 projectId, ICurrency.Currency currency)
        external
        view
        returns (uint256)
    {
        return projectEscrowBalances[projectId][currency];
    }

    /**
     * @dev Get registered office address for a project.
     */
    function getRegisteredOffice(uint256 projectId)
        external
        view
        returns (address)
    {
        return registeredOffices[projectId];
    }

    // Required to receive native currency
    receive() external payable {}
}
