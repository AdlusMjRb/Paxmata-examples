// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract PaxmataNFT is ERC721URIStorage, ERC721Enumerable, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdCounter;
    mapping(address => bool) public authorizedMinters;
    address public projectManager;
    bool private initialized;

    // Add this function to get the current token count
    function getCurrentTokenId() public view returns (uint256) {
        return _tokenIdCounter.current();
    }

    modifier onlyAuthorizedMinter() {
        require(authorizedMinters[msg.sender], "Caller is not authorized to mint");
        _;
    }
    
    function addAuthorizedMinter(address minter) external onlyOwner {
        authorizedMinters[minter] = true;
    }
    
    function removeAuthorizedMinter(address minter) external onlyOwner {
        authorizedMinters[minter] = false;
    }

    event ProjectManagerSet(address indexed projectManager);

    constructor() ERC721("Paxmata", "PAXMAP") {
        // Initialize with explicit values
        initialized = false;
    }

    function setProjectManager(address _projectManager) external onlyOwner {
        require(!initialized, "ProjectManager already set");
        require(_projectManager != address(0), "Invalid address");
        projectManager = _projectManager;
        initialized = true;
        emit ProjectManagerSet(_projectManager);
    }

    function safeMint(address to, string memory metadataUrl) 
        external 
        onlyAuthorizedMinter 
        returns (uint256) {
        require(msg.sender == projectManager, "Only ProjectManager can mint");
        require(to != address(0), "Invalid recipient");
        require(bytes(metadataUrl).length > 0, "Empty metadata URL");
        _tokenIdCounter.increment();
        uint256 tokenId = _tokenIdCounter.current();
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, metadataUrl);
        return tokenId;
    }

    // Override functions with explicit support for both parent contracts
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }
}
