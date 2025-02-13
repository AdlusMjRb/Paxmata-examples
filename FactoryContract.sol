// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./OfficeContract.sol";
import "./PaxmataEscrow.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IProjectManager.sol"; // Import IProjectManager to access ProjectData

/**
 * @title PaxmataFactory
 * @dev Factory contract for deploying Office and Escrow contracts.
 */
contract PaxmataFactory is Ownable {
    mapping(address => bool) public authorizedCreators;
    
    modifier onlyAuthorizedCreator() {
        require(authorizedCreators[msg.sender], "Caller is not authorized to create contracts");
        _;
    }
    
    function addAuthorizedCreator(address creator) external onlyOwner {
        authorizedCreators[creator] = true;
    }
    
    function removeAuthorizedCreator(address creator) external onlyOwner {
        authorizedCreators[creator] = false;
    }

    // State variables
    address public projectManager;
    bool private initialized;

    // Project contract tracking
    mapping(uint256 => address) public officeContracts;
    mapping(uint256 => address) public escrowContracts;

    // Events
    event OfficeContractCreated(
        uint256 indexed projectId,
        address indexed officeContractAddress
    );
    event EscrowContractCreated(
        uint256 indexed projectId,
        address indexed escrowContractAddress
    );
    event ProjectManagerSet(address indexed projectManager);

    constructor() {
        initialized = false;
    }

    /**
     * @dev Sets the ProjectManager address. Can only be called once.
     */
    function setProjectManager(address _projectManager) external onlyOwner {
        require(!initialized, "ProjectManager already set");
        require(_projectManager != address(0), "Invalid ProjectManager address");

        projectManager = _projectManager;
        initialized = true;

        emit ProjectManagerSet(_projectManager);
    }

    /**
     * @dev Creates new OfficeContract and PaxmataEscrow contracts for a project.
     */
  function createOfficeAndEscrow(
    address nftContractAddress,
    address projectManagerContract,
    uint256 projectId,
    address projectOwner,
    IProjectManager.ProjectData calldata projectData,
    address paxmataWallet
) external onlyAuthorizedCreator returns (address officeAddress, address escrowAddress) {
    // Input validation
    require(nftContractAddress != address(0), "Invalid NFT contract address");
    require(projectManagerContract != address(0), "Invalid ProjectManager address");
    require(projectOwner != address(0), "Invalid project owner address");
    require(paxmataWallet != address(0), "Invalid Paxmata wallet address");
    require(officeContracts[projectId] == address(0), "Project contracts already exist");

    // Create Escrow contract
    PaxmataEscrow escrow = new PaxmataEscrow(
        projectManagerContract,
        nftContractAddress,
        paxmataWallet
    );

    // Store escrow address
    escrowAddress = address(escrow);
    escrowContracts[projectId] = escrowAddress;

    emit EscrowContractCreated(projectId, escrowAddress);

    // Create Office contract, pass projectData and escrow address
    OfficeContract office = new OfficeContract(
        nftContractAddress,
        projectManagerContract,
        projectId,
        projectOwner,
        escrowAddress,
        projectData // Pass the projectData here
    );

    // Store office address
    officeAddress = address(office);
    officeContracts[projectId] = officeAddress;

    emit OfficeContractCreated(projectId, officeAddress);

    return (officeAddress, escrowAddress);
}


    /**
     * @dev Checks if contracts exist for a project.
     */
    function contractsExist(uint256 projectId) external view returns (bool) {
        return officeContracts[projectId] != address(0) &&
               escrowContracts[projectId] != address(0);
    }

    /**
     * @dev Gets the addresses of contracts for a project.
     */
    function getProjectContracts(uint256 projectId)
        external
        view
        returns (address office, address escrow)
    {
        return (officeContracts[projectId], escrowContracts[projectId]);
    }

    /**
     * @dev Modifier to restrict access to ProjectManager only.
     */
    modifier onlyProjectManager() {
        require(
            msg.sender == projectManager,
            "Only ProjectManager can call this function"
        );
        require(initialized, "ProjectManager not set");
        _;
    }
}
