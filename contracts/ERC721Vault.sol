// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract ERC721Vault is IERC721Receiver, ReentrancyGuard, Ownable {
    IERC721 public immutable nft;

    uint256 public totalSupply;
    uint256 private constant _MULTIPLIER = 1e18;
    uint256 private rewardIndex;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) private rewardIndexOf;
    mapping(address => uint256) private earned;
    mapping(address => uint256) private claimedRewards;
    mapping(address => uint256[]) private stakedTokenIds;
    mapping(uint256 => address) private stakedTokenOwner;
    mapping(address => mapping(uint256 => uint256)) private tokenIdToIndex;

    event Staked(address indexed user, uint256 indexed tokenId);
    event Unstaked(address indexed user, uint256 indexed tokenId);
    event Claimed(address indexed user, uint256 amount, uint256 totalClaimed);
    event Received(uint256 amount, uint256 rewardIndex);
    event RewardsUpdated(
        address indexed user,
        uint256 newEarned,
        uint256 newIndex
    );

    error NotNFTOwner();
    error NFTNotEligibleForStaking();
    error NFTNotStaked();
    error NFTNotStakedByUser();
    error ZeroRewards();
    error TransferFailed();
    error UnauthorizedTransfer();
    error ZeroAddress();
    error EmptyTokenArray();

    struct UserInfo {
        uint256 pendingRewards;
        uint256 claimedRewards;
        uint256[] stakedTokenIds;
    }

    /// @notice Sets up the staking contract with the NFT contract address
    /// @param _nft The address of the NFT contract
    /// @param _owner The address that will own this contract
    constructor(address _nft, address _owner) Ownable(_owner) {
        if (_nft == address(0)) revert ZeroAddress();
        nft = IERC721(_nft);
    }

    /// @notice Receives ETH and updates the reward index
    receive() external payable {
        if (totalSupply > 0) {
            uint256 reward = (msg.value * _MULTIPLIER) / totalSupply;
            rewardIndex += reward;
        } else {
            (bool success, ) = payable(owner()).call{value: msg.value}("");
            if (!success) revert TransferFailed();
        }
        emit Received(msg.value, rewardIndex);
    }

    /// @notice Returns user information including staked token IDs and rewards
    /// @param user Address of the user
    /// @return UserInfo containing pending rewards, claimed rewards, and staked token IDs
    function getUserInfo(address user) public view returns (UserInfo memory) {
        if (user == address(0)) revert ZeroAddress();
        return
            UserInfo({
                pendingRewards: getPendingRewards(user),
                claimedRewards: claimedRewards[user],
                stakedTokenIds: stakedTokenIds[user]
            });
    }

    /// @notice Returns the pending rewards for an account
    /// @param account The address of the account
    /// @return The amount of pending rewards
    function getPendingRewards(address account) public view returns (uint256) {
        return earned[account] + _calculateRewards(account);
    }

    /// @notice Calculates the rewards accumulated for a given account
    /// @param account The address of the account
    /// @return The calculated amount of rewards
    function _calculateRewards(address account) private view returns (uint256) {
        uint256 nftCount = balanceOf[account];
        if (nftCount == 0 || rewardIndex <= rewardIndexOf[account]) {
            return 0;
        }

        uint256 indexDiff = rewardIndex - rewardIndexOf[account];
        return (nftCount * indexDiff) / _MULTIPLIER;
    }

    /// @notice Updates the reward calculation for an account
    /// @param account The address of the account
    function _updateRewards(address account) private {
        uint256 newEarned = _calculateRewards(account);
        earned[account] += newEarned;
        rewardIndexOf[account] = rewardIndex;
        emit RewardsUpdated(account, earned[account], rewardIndex);
    }

    /// @notice Handles ERC721 token reception
    /// @dev Required by the IERC721Receiver interface
    function onERC721Received(
        address operator,
        address,
        uint256,
        bytes calldata
    ) public view override returns (bytes4) {
        // Check 1: Ensure the NFT is from the correct contract
        if (msg.sender != address(nft)) {
            revert NFTNotEligibleForStaking();
        }
        // Check 2: Ensure the transfer is initiated by the staking contract (via stake())
        if (operator != address(this)) {
            revert UnauthorizedTransfer();
        }
        return this.onERC721Received.selector;
    }

    /// @notice Allows users to stake their NFTs
    /// @param tokenIds Array of token IDs to stake
    function stake(uint256[] calldata tokenIds) external nonReentrant {
        uint256 length = tokenIds.length;
        if (length == 0) revert EmptyTokenArray();

        _updateRewards(msg.sender);
        address sender = msg.sender;
        uint256[] storage userTokens = stakedTokenIds[sender];

        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = tokenIds[i];

            if (nft.ownerOf(tokenId) != sender) {
                revert NotNFTOwner();
            }

            // Transfer NFT to the contract
            nft.safeTransferFrom(sender, address(this), tokenId);

            // Track token ownership
            stakedTokenOwner[tokenId] = sender;

            // Add to user's token array and track its index
            tokenIdToIndex[sender][tokenId] = userTokens.length;
            userTokens.push(tokenId);

            emit Staked(sender, tokenId);
        }

        balanceOf[sender] += length;
        totalSupply += length;
    }

    /// @notice Allows users to unstake their NFTs
    /// @param tokenIds Array of token IDs to unstake
    function unstake(uint256[] calldata tokenIds) external nonReentrant {
        uint256 length = tokenIds.length;
        if (length == 0) revert EmptyTokenArray();

        address sender = msg.sender;
        _updateRewards(sender);

        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = tokenIds[i];

            // Verify the contract owns the NFT
            if (nft.ownerOf(tokenId) != address(this)) {
                revert NFTNotStaked();
            }

            // Verify the user is the one who staked this NFT
            if (stakedTokenOwner[tokenId] != sender) {
                revert NFTNotStakedByUser();
            }

            // Transfer NFT back to user
            nft.safeTransferFrom(address(this), sender, tokenId);

            // Remove ownership record
            delete stakedTokenOwner[tokenId];
            _removeStakedTokenId(sender, tokenId);

            emit Unstaked(sender, tokenId);
        }

        balanceOf[sender] -= length;
        totalSupply -= length;
    }

    /// @notice Allows users to claim their staking rewards
    /// @return The amount of rewards claimed
    function claim() external nonReentrant returns (uint256) {
        address sender = msg.sender;

        // Update user rewards
        _updateRewards(sender);

        // Get the total rewards
        uint256 claimAmount = earned[sender];

        // Check if there are rewards to claim
        if (claimAmount == 0) {
            revert ZeroRewards();
        }

        // Reset user's earned rewards before transfer
        earned[sender] = 0;

        // Update claimed rewards
        claimedRewards[sender] += claimAmount;

        // Transfer the rewards
        (bool success, ) = payable(sender).call{value: claimAmount}("");
        if (!success) {
            revert TransferFailed();
        }

        emit Claimed(sender, claimAmount, claimedRewards[sender]);
        return claimAmount;
    }

    /// @notice Removes a staked token ID from the user's staked token list in O(1) time
    /// @param user Address of the user who is unstaking
    /// @param tokenId Token ID being unstaked
    function _removeStakedTokenId(address user, uint256 tokenId) private {
        uint256[] storage userTokens = stakedTokenIds[user];
        uint256 length = userTokens.length;

        // Get index of token to remove using the mapping
        uint256 index = tokenIdToIndex[user][tokenId];

        // Only proceed if index is valid
        if (index < length) {
            // Get the last token ID
            uint256 lastTokenId = userTokens[length - 1];

            // Move the last token to the removed position
            userTokens[index] = lastTokenId;

            // Update the index of the moved token
            tokenIdToIndex[user][lastTokenId] = index;

            // Remove the last element
            userTokens.pop();
        }

        // Clear the mapping entry for the removed token
        delete tokenIdToIndex[user][tokenId];
    }

    /// @notice Check if a token is staked by a specific user
    /// @param tokenId The token ID to check
    /// @param user The user address to verify against
    /// @return True if the token is staked by the user
    function isTokenStakedByUser(
        uint256 tokenId,
        address user
    ) external view returns (bool) {
        return stakedTokenOwner[tokenId] == user;
    }
}
