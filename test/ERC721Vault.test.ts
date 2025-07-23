import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import "@nomicfoundation/hardhat-chai-matchers";
import { ERC721Vault } from "../typechain-types/contracts/ERC721Vault";
import { MockERC721 } from "../typechain-types/contracts/mock/MockERC721";

//npx hardhat test test/ERC721Vault.test.ts

chai.use(chaiAsPromised);

describe("ERC721Vault", function () {
    // Token IDs
    const staker1TokenIds = [0n, 1n];
    const staker2TokenIds = [2n, 3n];
    const staker3TokenIds = [4n, 5n];
    const nonStakerTokenId = 6n;
    const anotherNftTokenIdStaker1 = 0n;

    async function deployERC721VaultFixture() {
        const [vaultOwner, staker1, staker2, staker3, nonStaker, attacker] = await ethers.getSigners();

        // Deploy Mock NFTs
        const MockERC721Factory = await ethers.getContractFactory("MockERC721");
        const mockNft = (await MockERC721Factory.deploy()) as MockERC721;
        await mockNft.waitForDeployment();
        const mockNftAddress = await mockNft.getAddress();

        const anotherMockNft = (await MockERC721Factory.deploy()) as MockERC721;
        await anotherMockNft.waitForDeployment();

        // FIX: Mint NFTs to the stakers so they actually own them
        for (const tokenId of staker1TokenIds) {
            await mockNft.mint(staker1.address, tokenId);
        }
        for (const tokenId of staker2TokenIds) {
            await mockNft.mint(staker2.address, tokenId);
        }
        for (const tokenId of staker3TokenIds) {
            await mockNft.mint(staker3.address, tokenId);
        }
        await mockNft.mint(nonStaker.address, nonStakerTokenId);
        await anotherMockNft.mint(staker1.address, anotherNftTokenIdStaker1);

        // Deploy Vault
        const ERC721VaultFactory = await ethers.getContractFactory("ERC721Vault");
        const erc721Vault = (await ERC721VaultFactory.deploy(mockNftAddress, vaultOwner.address)) as ERC721Vault;
        await erc721Vault.waitForDeployment();
        const erc721VaultAddress = await erc721Vault.getAddress();

        // Set approvals for all stakers
        for (const staker of [staker1, staker2, staker3, nonStaker]) {
            await mockNft.connect(staker).setApprovalForAll(erc721VaultAddress, true);
        }
        await anotherMockNft.connect(staker1).setApprovalForAll(erc721VaultAddress, true);

        return {
            erc721Vault,
            mockNft,
            anotherMockNft,
            vaultOwner,
            staker1,
            staker2,
            staker3,
            nonStaker,
            attacker,
            erc721VaultAddress,
            mockNftAddress,
            ERC721VaultFactory, // Return factory for constructor tests
        };
    }

    describe("Constructor", function () {
        it("Should set the correct NFT contract address and owner", async function () {
            const { erc721Vault, mockNftAddress, vaultOwner } = await loadFixture(deployERC721VaultFixture);
            expect(await erc721Vault.nft()).to.equal(mockNftAddress);
            expect(await erc721Vault.owner()).to.equal(vaultOwner.address);
        });

        it("Should initialize with zero total supply and rewards", async function () {
            const { erc721Vault, staker1 } = await loadFixture(deployERC721VaultFixture);
            expect(await erc721Vault.totalSupply()).to.equal(0n);
            expect(await erc721Vault.getPendingRewards(staker1.address)).to.equal(0n);
        });

        it("Should revert if NFT address is zero", async function () {
            // FIX: Get factory and owner from fixture to use in this test
            const { ERC721VaultFactory, vaultOwner } = await loadFixture(deployERC721VaultFixture);
            await expect(
                ERC721VaultFactory.deploy(ethers.ZeroAddress, vaultOwner.address)
            ).to.be.revertedWithCustomError(ERC721VaultFactory, "ZeroAddress");
        });
    });

    describe("Staking", function () {
        it("Should allow a user to stake multiple NFTs", async function () {
            const { erc721Vault, mockNft, staker1, erc721VaultAddress } = await loadFixture(deployERC721VaultFixture);

            await expect(erc721Vault.connect(staker1).stake(staker1TokenIds))
                .to.emit(erc721Vault, "Staked").withArgs(staker1.address, staker1TokenIds[0])
                .to.emit(erc721Vault, "Staked").withArgs(staker1.address, staker1TokenIds[1]);

            expect(await erc721Vault.balanceOf(staker1.address)).to.equal(staker1TokenIds.length);
            expect(await erc721Vault.totalSupply()).to.equal(staker1TokenIds.length);

            for (const tokenId of staker1TokenIds) {
                expect(await mockNft.ownerOf(tokenId)).to.equal(erc721VaultAddress);
                expect(await erc721Vault.isTokenStakedByUser(tokenId, staker1.address)).to.be.true;
            }
            const userInfo = await erc721Vault.getUserInfo(staker1.address);
            const stakedIds = userInfo.stakedTokenIds.map(id => BigInt(id));
            expect(stakedIds).to.have.deep.members(staker1TokenIds.map(id => BigInt(id)));
        });

        it("Should update rewards index for staker upon staking", async function () {
            const { erc721Vault, staker1, staker2, erc721VaultAddress } = await loadFixture(deployERC721VaultFixture);
            await staker2.sendTransaction({ to: erc721VaultAddress, value: ethers.parseEther("1") });
            await erc721Vault.connect(staker1).stake([staker1TokenIds[0]]);
            const userInfo = await erc721Vault.getUserInfo(staker1.address);
            expect(userInfo.pendingRewards).to.equal(0n); // Rewards for past distributions are not given
        });

        it("Should revert if staking zero tokens", async function () {
            const { erc721Vault, staker1 } = await loadFixture(deployERC721VaultFixture);
            await expect(erc721Vault.connect(staker1).stake([])).to.be.revertedWithCustomError(erc721Vault, "EmptyTokenArray");
        });

        it("Should revert if user does not own an NFT", async function () {
            const { erc721Vault, staker2 } = await loadFixture(deployERC721VaultFixture);
            await expect(
                erc721Vault.connect(staker2).stake([staker1TokenIds[0]]) // staker2 tries to stake staker1's token
            ).to.be.revertedWithCustomError(erc721Vault, "NotNFTOwner");
        });

        it("Should revert if NFT not approved", async function () {
            const { erc721Vault, mockNft, staker1, erc721VaultAddress } = await loadFixture(deployERC721VaultFixture);
            await mockNft.connect(staker1).setApprovalForAll(erc721VaultAddress, false);
            await expect(
                erc721Vault.connect(staker1).stake([staker1TokenIds[0]])
            ).to.be.reverted; // Reverts due to ERC721: "approve caller is not owner nor approved for all"
        });
    });

    describe("Unstaking", function () {
        // Setup a state where tokens are already staked for each test in this block
        async function deployAndStakeFixture() {
            const baseFixture = await loadFixture(deployERC721VaultFixture);
            await baseFixture.erc721Vault.connect(baseFixture.staker1).stake(staker1TokenIds);
            await baseFixture.erc721Vault.connect(baseFixture.staker2).stake(staker2TokenIds);
            return baseFixture;
        }

        it("Should allow a user to unstake their NFTs", async function () {
            const { erc721Vault, mockNft, staker1 } = await loadFixture(deployAndStakeFixture);
            const tokenToUnstake = [staker1TokenIds[0]];
            const initialTotalSupply = await erc721Vault.totalSupply();

            await expect(erc721Vault.connect(staker1).unstake(tokenToUnstake))
                .to.emit(erc721Vault, "Unstaked").withArgs(staker1.address, tokenToUnstake[0]);

            expect(await erc721Vault.balanceOf(staker1.address)).to.equal(staker1TokenIds.length - 1);
            expect(await erc721Vault.totalSupply()).to.equal(initialTotalSupply - 1n);
            expect(await mockNft.ownerOf(tokenToUnstake[0])).to.equal(staker1.address);
            expect(await erc721Vault.isTokenStakedByUser(tokenToUnstake[0], staker1.address)).to.be.false;
        });

        it("Should revert if unstaking zero tokens", async function () {
            const { erc721Vault, staker1 } = await loadFixture(deployAndStakeFixture);
            await expect(erc721Vault.connect(staker1).unstake([])).to.be.revertedWithCustomError(erc721Vault, "EmptyTokenArray");
        });

        it("Should revert if user tries to unstake an NFT they didn't stake", async function () {
            const { erc721Vault, staker2 } = await loadFixture(deployAndStakeFixture);
            await expect(
                erc721Vault.connect(staker2).unstake([staker1TokenIds[0]])
            ).to.be.revertedWithCustomError(erc721Vault, "NFTNotStakedByUser");
        });

        it("Should update rewards for user upon unstaking", async function () {
            const { erc721Vault, staker1, nonStaker, erc721VaultAddress } = await loadFixture(deployAndStakeFixture);
            await nonStaker.sendTransaction({ to: erc721VaultAddress, value: ethers.parseEther("1") });
            const rewardsBeforeUnstake = await erc721Vault.getPendingRewards(staker1.address);
            expect(rewardsBeforeUnstake).to.be.gt(0n);

            await erc721Vault.connect(staker1).unstake([staker1TokenIds[0]]);
            const finalPendingRewards = await erc721Vault.getPendingRewards(staker1.address);
            expect(finalPendingRewards).to.be.closeTo(rewardsBeforeUnstake, ethers.parseUnits("0.001", "ether"));
        });
    });

    describe("Rewards Distribution", function () {
        it("Should distribute rewards proportionally", async function () {
            const { erc721Vault, staker1, staker2, nonStaker, erc721VaultAddress } = await loadFixture(deployERC721VaultFixture);
            await erc721Vault.connect(staker1).stake(staker1TokenIds); // 2 NFTs
            await erc721Vault.connect(staker2).stake(staker2TokenIds); // 2 NFTs

            const rewardAmount = ethers.parseEther("1.0");
            await nonStaker.sendTransaction({ to: erc721VaultAddress, value: rewardAmount });

            const staker1Rewards = await erc721Vault.getPendingRewards(staker1.address);
            const staker2Rewards = await erc721Vault.getPendingRewards(staker2.address);

            expect(staker1Rewards).to.be.closeTo(ethers.parseEther("0.5"), ethers.parseUnits("0.001", "ether"));
            expect(staker2Rewards).to.be.closeTo(ethers.parseEther("0.5"), ethers.parseUnits("0.001", "ether"));
        });

        it("Should forward ETH to owner if totalSupply is 0", async function () {
            const { erc721Vault, vaultOwner, staker1, erc721VaultAddress } = await loadFixture(deployERC721VaultFixture);
            const ownerInitialBalance = await ethers.provider.getBalance(vaultOwner.address);
            const rewardAmount = ethers.parseEther("1.0");

            await staker1.sendTransaction({ to: erc721VaultAddress, value: rewardAmount });

            expect(await ethers.provider.getBalance(vaultOwner.address)).to.equal(ownerInitialBalance + rewardAmount);
        });
    });

    describe("Claiming", function () {
        it("Should allow a user to claim their rewards", async function () {
            const { erc721Vault, staker1, nonStaker, erc721VaultAddress } = await loadFixture(deployERC721VaultFixture);
            await erc721Vault.connect(staker1).stake(staker1TokenIds);
            await nonStaker.sendTransaction({ to: erc721VaultAddress, value: ethers.parseEther("1.0") });

            const initialBalance = await ethers.provider.getBalance(staker1.address);
            const pendingRewards = await erc721Vault.getPendingRewards(staker1.address);
            expect(pendingRewards).to.be.gt(0);

            const tx = await erc721Vault.connect(staker1).claim();
            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

            const finalBalance = await ethers.provider.getBalance(staker1.address);
            expect(finalBalance).to.be.closeTo(initialBalance + pendingRewards - gasUsed, ethers.parseUnits("0.001", "ether"));

            const userInfo = await erc721Vault.getUserInfo(staker1.address);
            expect(userInfo.pendingRewards).to.equal(0n);
        });

        it("Should revert if trying to claim zero rewards", async function () {
            const { erc721Vault, staker1 } = await loadFixture(deployERC721VaultFixture);
            await erc721Vault.connect(staker1).stake(staker1TokenIds);
            await expect(erc721Vault.connect(staker1).claim()).to.be.revertedWithCustomError(erc721Vault, "ZeroRewards");
        });
    });

    describe("onERC721Received Hook", function () {
        it("Should revert if an NFT from a non-approved contract is sent directly", async function () {
            const { erc721Vault, anotherMockNft, staker1, erc721VaultAddress } = await loadFixture(deployERC721VaultFixture);
            await expect(
                anotherMockNft.connect(staker1)["safeTransferFrom(address,address,uint256)"](
                    staker1.address,
                    erc721VaultAddress,
                    anotherNftTokenIdStaker1
                )
            ).to.be.revertedWithCustomError(erc721Vault, "NFTNotEligibleForStaking");
        });

        it("Should revert if an NFT is sent directly by user (not via stake function)", async function () {
            const { erc721Vault, mockNft, staker1, erc721VaultAddress } = await loadFixture(deployERC721VaultFixture);
            await expect(
                mockNft.connect(staker1)["safeTransferFrom(address,address,uint256)"](
                    staker1.address,
                    erc721VaultAddress,
                    staker1TokenIds[0]
                )
            ).to.be.revertedWithCustomError(erc721Vault, "UnauthorizedTransfer");
        });
    });
});