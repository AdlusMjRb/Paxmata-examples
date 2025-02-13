// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IPaxmataEscrow.sol";
import "./interfaces/ICurrency.sol";
import "./interfaces/IProjectManager.sol";

contract OfficeContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Immutable state variables - set once during construction
    uint256 public immutable tokenId;
    address public immutable projectOwner;
    address private immutable nftContract;
    address private immutable projectManager;
    IPaxmataEscrow public immutable escrowContract;

    // Mutable state variables
    bytes32 public projectDataHash;
    uint256 public milestoneCounter;
    bool public channelClosed;

    // Milestone structure definition
    struct Milestone {
        uint256 id;                   // Unique identifier
        uint256 parentMilestoneId;    // ID of parent milestone (0 if no parent)
        uint256[] childMilestoneIds;  // IDs of child milestones
        uint256 payment;              // Payment amount (optional, can be 0)
        uint256 deadline;             // Deadline timestamp (optional, can be 0)
        uint256 timestamp;            // Creation timestamp
        bytes32 milestoneHash;        // Hash of milestone data
        bool completed;               // Completion status
        bool verified;                // Verification status
        uint8 completionPercentage;   // Progress percentage
        address recipient;            // Payment recipient (optional, defaults to project owner)
    }

    // Helper struct for batch operations
    struct BatchProcessingData {
        uint256 initialMilestoneCount;
        uint256 parentMilestoneCount;
        bytes32 currentProjectHash;
        bytes32 newRoot;
        bytes32 oldHash;
    }

    // Storage mappings
    mapping(uint256 => Milestone) public milestones;
    mapping(address => bool) public authorizedDevelopers;

    // Custom error definitions
    error Unauthorized();
    error InvalidAddress();
    error MilestoneNotFound();
    error DeadlinePassed();
    error AlreadyCompleted();
    error NotCompleted();
    error AlreadyVerified();
    error ChannelAlreadyClosed();
    error InsufficientPayment();
    error ArrayLengthMismatch();

    // Events
    event ProjectHashUpdated(
        uint256 indexed tokenId,
        bytes32 oldHash,
        bytes32 newHash,
        uint256 timestamp
    );

    event MilestoneHashCreated(
        uint256 indexed tokenId,
        uint256 indexed milestoneId,
        bytes32 milestoneHash,
        bytes32[] parentHashes,
        uint256 timestamp
    );

    event MerkleRootUpdated(
        uint256 indexed tokenId,
        bytes32 merkleRoot,
        uint256 totalLeaves,
        uint256 timestamp
    );

    event BatchOperationCompleted(
        uint256 indexed tokenId,
        uint256 totalMilestones,
        bytes32 newMerkleRoot,
        uint256 timestamp
    );

    event BatchOperationExecuted(
        uint256 indexed tokenId,
        uint256 totalAmount,
        ICurrency.Currency currency,
        uint256 totalMilestones
    );

    event MilestoneAdded(
        uint256 indexed milestoneId,
        uint256 indexed parentId,
        address indexed recipient,
        uint256 payment,
        uint256 deadline,
        bytes32 milestoneHash
    );

    event MilestoneCompleted(
        uint256 indexed milestoneId,
        address indexed developer,
        uint8 completionPercentage
    );

    event MilestoneVerified(
        uint256 indexed milestoneId,
        address indexed verifier,
        uint256 payment
    );

    event DeveloperAuthorized(address indexed developer);
    event DeveloperDeauthorized(address indexed developer);
    event ChannelClosed(uint256 timestamp);
    event ProjectHashCreated(uint256 indexed tokenId, bytes32 projectHash);

    // Access control modifiers
    modifier onlyProjectOwner() {
        if (msg.sender != projectOwner) revert Unauthorized();
        _;
    }

    modifier onlyDeveloper() {
        if (!authorizedDevelopers[msg.sender]) revert Unauthorized();
        _;
    }

    modifier channelOpen() {
        if (channelClosed) revert("Channel closed");
        _;
    }

    constructor(
        address _nftContract,
        address _projectManager,
        uint256 _tokenId,
        address _projectOwner,
        address _escrowContract,
                    IProjectManager.ProjectData memory _projectData
    ) {
        // Basic validations for addresses
        require(_nftContract != address(0), "Invalid NFT contract address");
        require(_projectManager != address(0), "Invalid Project Manager address");
        require(_projectOwner != address(0), "Invalid Project Owner address");
        require(_escrowContract != address(0), "Invalid Escrow contract address");

        // Set immutable variables
        nftContract = _nftContract;
        projectManager = _projectManager;
        tokenId = _tokenId;
        projectOwner = _projectOwner;
        escrowContract = IPaxmataEscrow(_escrowContract);

    projectDataHash = keccak256(
        abi.encode(
            // Core project details
            keccak256(bytes(_projectData.projectDescription)),
            _projectData.estimatedCost,
            keccak256(bytes(_projectData.estimatedTimescale)),
            keccak256(bytes(_projectData.projectLocation)),
            _projectData.isInvestable,
            _projectData.investmentGoal,
            keccak256(bytes(_projectData.projectType)),
            _projectData.isDonationEnabled,
            _projectData.donationsReceived,
            _projectData.isComplete,
            _projectData.completionPercentage,
            _projectData.verificationPercentage,
            _projectData.totalMilestones,
            _projectData.completedMilestones,
            _projectData.verifiedMilestones,
            keccak256(bytes(_projectData.status)),
            _projectData.projectMilestoneCounter,

            // Critical data
            _projectData.mintTimestamp,
            _projectData.ethereumAddress,
            keccak256(bytes(_projectData.userId))
        )
    );

    emit ProjectHashCreated(tokenId, projectDataHash);

        // Setup escrow relationships
        try escrowContract.registerProjectOffice(_tokenId, address(this)) {
            // Office registration successful
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Failed to register office: ", reason)));
        }

        try escrowContract.registerProjectOwner(_tokenId, _projectOwner) {
            // Owner registration successful
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Failed to register owner: ", reason)));
        }
    }

    // Core function to add a single milestone
    function _addMilestone(
        uint256 parentId,
        uint256 payment,
        uint256 deadline,
        address recipient
    ) internal {
        milestoneCounter++;

        // Use project owner as default recipient if none specified
        address milestoneRecipient = recipient == address(0) ? projectOwner : recipient;

        // Create milestone hash
        bytes32 milestoneHash = _hashMilestoneData(
            milestoneCounter,
            parentId,
            payment,         // Can be 0 for non-payment milestones
            deadline,        // Can be 0 for no deadline
            block.timestamp,
            new uint256[](0),
            milestoneRecipient
        );

        // Create milestone
        Milestone storage milestone = milestones[milestoneCounter];
        milestone.id = milestoneCounter;
        milestone.parentMilestoneId = parentId;
        milestone.payment = payment;
        milestone.deadline = deadline;
        milestone.timestamp = block.timestamp;
        milestone.milestoneHash = milestoneHash;
        milestone.recipient = milestoneRecipient;
        milestone.childMilestoneIds = new uint256[](0);
        milestone.completed = false;
        milestone.verified = false;
        milestone.completionPercentage = 0;

        // If this is a child milestone, add it to parent's children
        if (parentId != 0) {
            milestones[parentId].childMilestoneIds.push(milestoneCounter);
        }
    }

    // Helper function to add multiple milestones with same parent
    function _addMilestones(
        uint256 parentId,
        uint256[] calldata payments,
        uint256[] calldata deadlines,
        address[] calldata recipients
    ) internal {
        // Validate array lengths match
        if (
            payments.length != deadlines.length ||
            payments.length != recipients.length
        ) revert ArrayLengthMismatch();

        // Add each milestone
        for (uint256 i = 0; i < payments.length; i++) {
            _addMilestone(
                parentId,
                payments[i],
                deadlines[i],
                recipients[i]
            );
        }
    }

    // Public functions for adding milestones directly
    function addParentMilestones(
        uint256[] calldata payments,
        uint256[] calldata deadlines,
        address[] calldata recipients
    ) public onlyProjectOwner channelOpen {
        _addMilestones(0, payments, deadlines, recipients);
    }

    function addChildMilestones(
        uint256 parentId,
        uint256[] calldata payments,
        uint256[] calldata deadlines,
        address[] calldata recipients
    ) public onlyProjectOwner channelOpen {
        // Check parent exists
        require(milestones[parentId].id != 0, "Parent milestone not found");
        _addMilestones(parentId, payments, deadlines, recipients);
    }

    // Helper function to hash milestone data
    function _hashMilestoneData(
        uint256 milestoneId,
        uint256 parentId,
        uint256 payment,
        uint256 deadline,
        uint256 timestamp,
        uint256[] memory childMilestoneIds,
        address recipient
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                milestoneId,
                parentId,
                payment,
                deadline,
                timestamp,
                keccak256(abi.encodePacked(childMilestoneIds)),
                recipient
            )
        );
    }

    function batchCreateMilestonesAndAllocate(
        uint256[] calldata parentPayments,
        uint256[] calldata parentDeadlines,
        address[] calldata parentRecipients,
        uint256[] calldata childParentIds,
        uint256[] calldata childPayments,
        uint256[] calldata childDeadlines,
        address[] calldata childRecipients,
        ICurrency.Currency currency,
        uint256 depositAmount
    ) external payable onlyProjectOwner channelOpen nonReentrant {
        // Initial validation of batch size
        require(parentPayments.length <= 10, "Too many parent milestones");
        require(childPayments.length <= 20, "Too many child milestones");
        
        // Validate array lengths
        _validateArrayLengths(
            parentPayments,
            parentDeadlines,
            parentRecipients,
            childParentIds,
            childPayments,
            childDeadlines,
            childRecipients
        );

        // Setup batch data
        BatchProcessingData memory batchData = BatchProcessingData({
            initialMilestoneCount: milestoneCounter,
            parentMilestoneCount: 0,
            currentProjectHash: projectDataHash,
            newRoot: bytes32(0),
            oldHash: projectDataHash
        });

        // Calculate total required funds (only from non-zero payments)
        uint256 totalRequired = 0;
        for (uint256 i = 0; i < parentPayments.length; i++) {
            if (parentPayments[i] > 0) {
                totalRequired += parentPayments[i];
            }
        }
        for (uint256 i = 0; i < childPayments.length; i++) {
            if (childPayments[i] > 0) {
                totalRequired += childPayments[i];
            }
        }

        // Check existing project balance
        uint256 existingBalance = escrowContract.getProjectBalance(tokenId, currency);
        
        // Validate funds only if there are payments to handle
        if (totalRequired > 0) {
            if (totalRequired > existingBalance) {
                require(
                    depositAmount >= (totalRequired - existingBalance),
                    "Insufficient additional funds"
                );
            } else {
                require(depositAmount == 0, "No additional funds needed");
            }
        }

        // Process parent milestones
        if (parentPayments.length > 0) {
            for (uint256 i = 0; i < parentPayments.length; i++) {

                // Only validate deadline if it's non-zero
                if (parentDeadlines[i] > 0) {
                    require(
                        parentDeadlines[i] > block.timestamp,
                        "Parent deadline must be in future"
                    );
                }
            }
            _processParentMilestones(
                parentPayments,
                parentDeadlines,
                parentRecipients,
                batchData
            );
        }

        // Process child milestones
        if (childPayments.length > 0) {
            batchData.parentMilestoneCount = milestoneCounter;
            
            for (uint256 i = 0; i < childPayments.length; i++) {
                // Only validate deadline if it's non-zero
                if (childDeadlines[i] > 0) {
                    require(
                        childDeadlines[i] > block.timestamp,
                        "Child deadline must be in future"
                    );
                }
                require(
                    childParentIds[i] <= milestoneCounter && childParentIds[i] > 0,
                    "Invalid parent milestone ID"
                );
            }
            
            _processChildMilestones(
                childParentIds,
                childPayments,
                childDeadlines,
                childRecipients,
                batchData
            );
        }

        // Update Merkle root
        _updateMerkleRoot(batchData);

        // Handle deposits and allocations only if there are payments
        if (totalRequired > 0) {
            if (depositAmount > 0) {
                if (currency == ICurrency.Currency.DEV) {
                    require(msg.value == depositAmount, "Incorrect DEV amount");
                }
                _handleDepositsAndAllocations(depositAmount, currency);
            }

            if (existingBalance > 0) {
                _allocateExistingFunds(existingBalance, currency);
            }
        }

        emit BatchOperationCompleted(
            tokenId,
            milestoneCounter,
            batchData.newRoot,
            block.timestamp
        );
    }

    function _processParentMilestones(
        uint256[] calldata payments,
        uint256[] calldata deadlines,
        address[] calldata recipients,
        BatchProcessingData memory batchData
    ) internal {
        _addMilestones(0, payments, deadlines, recipients);
        
        for (uint256 i = batchData.initialMilestoneCount + 1; i <= milestoneCounter; i++) {
            bytes32[] memory parentHashes = new bytes32[](1);
            parentHashes[0] = batchData.currentProjectHash;
            
            emit MilestoneHashCreated(
                tokenId,
                i,
                milestones[i].milestoneHash,
                parentHashes,
                block.timestamp
            );
        }
    }

    function _processChildMilestones(
        uint256[] calldata parentIds,
        uint256[] calldata payments,
        uint256[] calldata deadlines,
        address[] calldata recipients,
        BatchProcessingData memory batchData
    ) internal {
        // Add each child milestone with its correct parent
        for (uint256 i = 0; i < parentIds.length; i++) {
            _addMilestone(
                parentIds[i],
                payments[i],
                deadlines[i],
                recipients[i]
            );

            bytes32[] memory parentHashes = new bytes32[](2);
            parentHashes[0] = batchData.currentProjectHash;
            parentHashes[1] = milestones[parentIds[i]].milestoneHash;
            
            emit MilestoneHashCreated(
                tokenId,
                milestoneCounter,
                milestones[milestoneCounter].milestoneHash,
                parentHashes,
                block.timestamp
            );
        }
    }

    function _validateArrayLengths(
        uint256[] calldata parentPayments,
        uint256[] calldata parentDeadlines,
        address[] calldata parentRecipients,
        uint256[] calldata childParentIds,
        uint256[] calldata childPayments,
        uint256[] calldata childDeadlines,
        address[] calldata childRecipients
    ) internal pure {
        require(
            parentPayments.length == parentDeadlines.length &&
            parentPayments.length == parentRecipients.length,
            "Parent arrays length mismatch"
        );
        
        require(
            childParentIds.length == childPayments.length &&
            childPayments.length == childDeadlines.length &&
            childPayments.length == childRecipients.length,
            "Child arrays length mismatch"
        );
    }

    // Fund allocation and handling functions
    function _handleDepositsAndAllocations(
        uint256 depositAmount,
        ICurrency.Currency currency
    ) internal {
        // Handle DEV (native token) deposits
        if (currency == ICurrency.Currency.DEV) {
            require(msg.value == depositAmount, "Incorrect DEV amount");
            escrowContract.depositProjectFunds{value: msg.value}(
                tokenId,
                currency,
                depositAmount
            );
        } 
        // Handle ERC20 token deposits
        else {
            address tokenAddress = escrowContract.getSupportedTokenAddress(currency);
            require(tokenAddress != address(0), "Unsupported token");
            
            IERC20 token = IERC20(tokenAddress);
            token.safeTransferFrom(msg.sender, address(this), depositAmount);
            token.safeApprove(address(escrowContract), depositAmount);
            
            escrowContract.depositProjectFunds(
                tokenId,
                currency,
                depositAmount
            );
        }

        _allocateFundsToMilestones(depositAmount, currency);
    }

    function _allocateFundsToMilestones(
        uint256 depositAmount,
        ICurrency.Currency currency
    ) internal {
        uint256 allocated = 0;
        
        // Only allocate to milestones with non-zero payments
        for (uint256 i = 1; i <= milestoneCounter; i++) {
            uint256 payment = milestones[i].payment;
            if (payment > 0) {
                escrowContract.allocateFundsToMilestone(
                    tokenId,
                    i,
                    payment,
                    currency
                );
                allocated += payment;
            }
        }
        
        require(allocated == depositAmount, "Allocation mismatch");
    }

    function _allocateExistingFunds(uint256 amount, ICurrency.Currency currency) internal {
        uint256 allocated = 0;
        
        // Allocate existing funds to milestones with non-zero payments
        for (uint256 i = 1; i <= milestoneCounter; i++) {
            uint256 payment = milestones[i].payment;
            if (payment > 0 && allocated + payment <= amount) {
                escrowContract.allocateFundsToMilestone(
                    tokenId,
                    i,
                    payment,
                    currency
                );
                allocated += payment;
            }
        }
        
        require(allocated == amount, "Allocation mismatch");
    }

    // Merkle tree and hash functions
    function _updateMerkleRoot(BatchProcessingData memory batchData) internal {
        bytes32[] memory leaves = new bytes32[](milestoneCounter + 1);
        leaves[0] = batchData.currentProjectHash;
        
        for (uint256 i = 1; i <= milestoneCounter; i++) {
            leaves[i] = milestones[i].milestoneHash;
        }
        
        batchData.newRoot = _computeMerkleRoot(leaves);
        batchData.oldHash = projectDataHash;
        projectDataHash = batchData.newRoot;
        
        emit ProjectHashUpdated(tokenId, batchData.oldHash, batchData.newRoot, block.timestamp);
        emit MerkleRootUpdated(tokenId, batchData.newRoot, leaves.length, block.timestamp);
    }

    function _computeMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 0) return bytes32(0);
        if (leaves.length == 1) return leaves[0];

        while (leaves.length > 1) {
            uint256 length = leaves.length;
            uint256 newLength = (length + 1) / 2;
            bytes32[] memory newLeaves = new bytes32[](newLength);

            for (uint256 i = 0; i < newLength; i++) {
                if (2 * i + 1 < length) {
                    newLeaves[i] = _hashPair(leaves[2 * i], leaves[2 * i + 1]);
                } else {
                    newLeaves[i] = _hashPair(leaves[2 * i], leaves[2 * i]);
                }
            }
            leaves = newLeaves;
        }
        return leaves[0];
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b 
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    // Milestone completion and verification
    function completeMilestone(uint256 milestoneId)
        external
        onlyDeveloper
        channelOpen
    {
        Milestone storage milestone = milestones[milestoneId];
        if (milestone.id == 0) revert MilestoneNotFound();
        if (milestone.completed) revert AlreadyCompleted();
        // Only check deadline if it's set
        if (milestone.deadline > 0 && block.timestamp > milestone.deadline)
            revert DeadlinePassed();

        milestone.completed = true;
        milestone.completionPercentage = 100;

        emit MilestoneCompleted(milestoneId, msg.sender, 100);
    }

    function verifyMilestone(uint256 milestoneId, ICurrency.Currency currency)
        external
        onlyProjectOwner
        nonReentrant
        channelOpen
    {
        Milestone storage milestone = milestones[milestoneId];
        if (milestone.id == 0) revert MilestoneNotFound();
        if (!milestone.completed) revert NotCompleted();
        if (milestone.verified) revert AlreadyVerified();

        milestone.verified = true;

        // Only release payment if milestone has non-zero payment
        if (milestone.payment > 0) {
            escrowContract.releasePayment(
                tokenId,
                milestoneId,
                milestone.recipient,
                milestone.payment,
                currency
            );
        }

        emit MilestoneVerified(milestoneId, msg.sender, milestone.payment);
    }

    // Developer management
    function authorizeDeveloper(address developer) external onlyProjectOwner {
        if (developer == address(0)) revert InvalidAddress();
        authorizedDevelopers[developer] = true;
        emit DeveloperAuthorized(developer);
    }

    function deauthorizeDeveloper(address developer) external onlyProjectOwner {
        if (developer == address(0)) revert InvalidAddress();
        authorizedDevelopers[developer] = false;
        emit DeveloperDeauthorized(developer);
    }

    // Channel management
    function closeChannel() external onlyProjectOwner {
        if (channelClosed) revert ChannelAlreadyClosed();
        channelClosed = true;
        emit ChannelClosed(block.timestamp);
    }

    // View functions
    function getMilestoneData(uint256 milestoneId) external view returns (
        uint256 id,
        uint256 parentId,
        uint256 payment,
        uint256 deadline,
        address recipient,
        bool completed,
        bool verified
    ) {
        Milestone storage milestone = milestones[milestoneId];
        return (
            milestone.id,
            milestone.parentMilestoneId,
            milestone.payment,
            milestone.deadline,
            milestone.recipient,
            milestone.completed,
            milestone.verified
        );
    }

    // Required for receiving ETH
    receive() external payable {}
}
