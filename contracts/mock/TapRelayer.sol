// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILastTap {
  function tap() external;
}

contract TapRelayer {
    ILastTap public immutable gameContractInstance; // Use the interface type
    address public owner;

    event Approved(address indexed token, address indexed spender, uint256 amount);
    event TappedViaRelay(address indexed relayer);

    constructor(address _gameContract) {
        // When casting to an interface, you typically don't need the 'payable' cast on the address
        // unless the interface functions themselves are payable and you're trying to send value.
        // Since ILastTap.tap() is not payable, this direct cast is fine.
        gameContractInstance = ILastTap(_gameContract);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "TapRelayer: Not owner");
        _;
    }

    function approveLastTap(address _tokenAddress, uint256 _amount) external onlyOwner {
        IERC20 token = IERC20(_tokenAddress);
        // address(gameContractInstance) correctly gets the address of the game contract
        token.approve(address(gameContractInstance), _amount);
        emit Approved(_tokenAddress, address(gameContractInstance), _amount);
    }

    function relayTap() external onlyOwner {
        // Ensure this contract (the relayer) has enough tokens and has approved LastTap
        // The actual token transfer will be initiated by LastTap from this contract's address
        gameContractInstance.tap();
        emit TappedViaRelay(address(this));
    }

    // Allow contract to receive ETH (e.g., for gas if needed, though owner pays for tx)
    receive() external payable {}
}