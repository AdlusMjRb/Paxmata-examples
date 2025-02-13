// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./PaxmataNFT.sol";
import "./PaxmataFactory.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IProjectManager.sol";

contract PaxmataProjectManager is IProjectManager, Ownable {
    // Event declarations
    event ProjectCreated(
        uint256 indexed tokenId,
        address indexed owner,
        address officeContract,
        address escrowContract
    );
    event FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );

    // Debug events
    event Debug_StartCreateProject(address indexed to, string metadataUrl);
    event Debug_BeforeNFTMint(address indexed to, string metadataUrl);
    event Debug_AfterNFTMint(uint256 tokenId);
    event Debug_BeforeFactoryCall(uint256 tokenId, address indexed to);
    event Debug_AfterFactoryCall(uint256 tokenId, address office, address escrow);
    event Debug_Error(string message);

    // Core contracts
    PaxmataNFT public nftContract;
    PaxmataFactory public factoryContract;
    address public paxmataWallet;

    // Project tracking
    mapping(uint256 => address) public projectOffices;
    mapping(uint256 => address) public projectOwners;

    constructor(address _nftContractAddress, address _paxmataWallet, address _factoryAddress) {
        require(_nftContractAddress != address(0), "Invalid NFT contract address");
        require(_paxmataWallet != address(0), "Invalid Paxmata wallet address");
        require(_factoryAddress != address(0), "Invalid factory address");
        
        nftContract = PaxmataNFT(_nftContractAddress);
        factoryContract = PaxmataFactory(_factoryAddress);
        paxmataWallet = _paxmataWallet;
    }

    function createProject(address to, string calldata metadataUrl, ProjectData calldata projectData) external returns (uint256 tokenId) {
        emit Debug_StartCreateProject(to, metadataUrl);

        // Validate inputs
        require(to != address(0), "Invalid recipient address");
        require(bytes(metadataUrl).length > 0, "Empty metadata URL");
        require(projectData.ethereumAddress != address(0), "Invalid Ethereum address");

        // Mint NFT first
        emit Debug_BeforeNFTMint(to, metadataUrl);
        try nftContract.safeMint(to, metadataUrl) returns (uint256 mintedTokenId) {
            emit Debug_AfterNFTMint(mintedTokenId);
            tokenId = mintedTokenId;

            projectOwners[tokenId] = to;

            // Deploy contracts via factory
            emit Debug_BeforeFactoryCall(tokenId, to);
            try factoryContract.createOfficeAndEscrow(
                address(nftContract),
                address(this),
                tokenId,
                to,
                projectData,
                paxmataWallet
            ) returns (address officeContract, address escrowContract) {
                emit Debug_AfterFactoryCall(tokenId, officeContract, escrowContract);

                // Store office contract reference
                projectOffices[tokenId] = officeContract;

                emit ProjectCreated(
                    tokenId,
                    to,
                    officeContract,
                    escrowContract
                );

                return tokenId;
            } catch Error(string memory reason) {
                emit Debug_Error(reason);
                revert(reason);
            }

        } catch Error(string memory reason) {
            emit Debug_Error(reason);
            revert(reason);
        }
    }


    // Add view functions to help debug state
function getProjectState(uint256 tokenId) external view returns (
    address owner,
    address office,
    bool hasNFT,
    bool hasOffice
) {
    owner = projectOwners[tokenId];
    office = projectOffices[tokenId];
    try nftContract.ownerOf(tokenId) returns (address) {
        hasNFT = true;
    } catch {
        hasNFT = false;
    }
    hasOffice = office != address(0);
}

    function verifyPermissions() external view returns (
        bool pmCanMint,
        bool pmCanCreateContracts
    ) {
        pmCanMint = nftContract.authorizedMinters(address(this));
        pmCanCreateContracts = factoryContract.authorizedCreators(address(this));
    }


    /**
     * @dev Gets the project owner for a given tokenId.
     */
    function getProjectOwner(uint256 tokenId) external view returns (address) {
        return projectOwners[tokenId];
    }

    /**
     * @dev Updates the factory address. Can only be called by the owner.
     */
    function updateFactory(address _newFactoryAddress) external onlyOwner {
        require(_newFactoryAddress != address(0), "Invalid factory address");
        address oldFactory = address(factoryContract);
        factoryContract = PaxmataFactory(_newFactoryAddress);
        emit FactoryUpdated(oldFactory, _newFactoryAddress);
    }
}
