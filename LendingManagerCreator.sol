// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./ProjectLendingManager.sol";

/**
 * @title LendingManagerCreator
 * @dev Helper contract to create ProjectLendingManager instances
 */
contract LendingManagerCreator {
    address public owner;
    
    constructor() {
        owner = msg.sender;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }
    
    function setOwner(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid owner address");
        owner = _newOwner;
    }
    
    function createLendingManager(
        uint256 _projectId,
        address _projectOwner,
        address _poolAddress,
        address _projectManagerContract,
        address _escrowAddress
    ) external returns (address) {
        // Only allow Factory to call this
        require(msg.sender == owner, "Unauthorized caller");
        
        ProjectLendingManager lendingManager = new ProjectLendingManager(
            _projectId,
            _projectOwner,
            _poolAddress,
            _projectManagerContract,
            _escrowAddress
        );
        
        return address(lendingManager);
    }
}
