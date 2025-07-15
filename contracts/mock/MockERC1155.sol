
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";

/**
 * @title MockERC1155
 * @dev A mock ERC1155 contract that includes ERC2981 royalty support for testing.
 */
contract MockERC1155 is ERC1155, ERC2981 {
    /**
     * @param royaltyRecipient The address to receive royalty payments.
     * @param royaltyBps The royalty fee in basis points (e.g., 500 for 5%).
     */
    constructor(address royaltyRecipient, uint96 royaltyBps) ERC1155("Mock URI") {
        _setDefaultRoyalty(royaltyRecipient, royaltyBps);
    }

    /**
     * @dev Mints new tokens to a given address.
     * Public visibility for ease of use in test environments.
     */
    function mint(address to, uint256 id, uint256 amount, bytes memory data) public {
        _mint(to, id, amount, data);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     * This override is required because both ERC1155 and ERC2981 implement this.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}