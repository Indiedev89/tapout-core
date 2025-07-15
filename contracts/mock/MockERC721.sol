// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockERC721
 * @dev A simple mock ERC721 contract for testing purposes.
 */
contract MockERC721 is ERC721 {
    constructor() ERC721("Mock NFT", "MOCK") {}

    /**
     * @dev Mints a new token with a specific ID to a given address.
     * Public visibility for ease of use in test environments.
     */
    function mint(address to, uint256 tokenId) public {
        _safeMint(to, tokenId);
    }
}