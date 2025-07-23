import { expect } from "chai";
import { ethers } from "hardhat";
import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import { MockERC20 } from "../typechain-types/contracts/mock/MockERC20";
import { Tapout, TapRelayer } from "../typechain-types";

//npx hardhat test test/Tapout.test.ts

chai.use(chaiAsPromised);

// Helper function to calculate net amount and owner fee
const calculateNetAndFee = (
  grossAmount: bigint,
  feePercent: bigint
): { netAmount: bigint; ownerFee: bigint } => {
  const ownerFee = (grossAmount * feePercent) / 100n;
  const netAmount = grossAmount - ownerFee;
  return { netAmount, ownerFee };
};

describe("Tapout Game", function () {
  // We define a fixture to reuse the same setup in every test.
  async function deployTapoutFixture() {
    // Get signers
    const [owner, player1, player2, player3, otherPlayer] = await ethers.getSigners();

    // Set constants
    const baseTapCost = ethers.parseUnits("10", 18); // 10 tokens
    const initialPrizePool = ethers.parseEther("1"); // 1 ETH
    const baseDuration = 60n; // 60 seconds
    const tapCostIncreasePercent = 1000n; // 10% in BPS (1000 / 10000)
    const choiceFee = ethers.parseUnits("5", 18); // 5 tokens

    // Deploy token
    const GameTokenFactory = await ethers.getContractFactory("MockERC20");
    const gameToken = (await GameTokenFactory.deploy(
      "Tapout Token",
      "TAP",
      ethers.parseUnits("1000000", 18),
      18
    )) as MockERC20;
    await gameToken.waitForDeployment();
    const gameTokenAddress = await gameToken.getAddress();

    // Deploy Tapout game
    const TapoutFactory = await ethers.getContractFactory("Tapout");
    const tapout = (await TapoutFactory.deploy()) as Tapout;
    await tapout.waitForDeployment();
    const tapoutAddress = await tapout.getAddress();

    // Get Fee Percent from Contract
    const devFeePercent = await tapout.DEV_FEE_PERCENT();

    // Transfer tokens to players
    const playerTokenAmount = ethers.parseUnits("1000", 18);
    await gameToken.transfer(player1.address, playerTokenAmount);
    await gameToken.transfer(player2.address, playerTokenAmount);
    await gameToken.transfer(player3.address, playerTokenAmount);
    await gameToken.transfer(otherPlayer.address, playerTokenAmount);

    // Approve tokens for the game
    for (const player of [player1, player2, player3, otherPlayer]) {
      await gameToken.connect(player).approve(tapoutAddress, playerTokenAmount);
    }

    // Fund Prize Pool (BEFORE initialize)
    await owner.sendTransaction({
      to: tapoutAddress,
      value: initialPrizePool,
    });

    // Initialize the game
    await tapout.initialize(
      gameTokenAddress,
      baseDuration,
      baseTapCost,
      tapCostIncreasePercent,
      choiceFee
    );

    return {
      tapout,
      gameToken,
      owner,
      player1,
      player2,
      player3,
      otherPlayer,
      baseTapCost,
      initialPrizePool,
      baseDuration,
      tapCostIncreasePercent,
      choiceFee,
      devFeePercent,
      tapoutAddress,
      gameTokenAddress,
    };
  }

  describe("Game Initialization", function () {
    it("Should initialize game with correct parameters", async function () {
      const { tapout, gameTokenAddress, baseDuration, baseTapCost, tapCostIncreasePercent, choiceFee, initialPrizePool, devFeePercent } = await loadFixture(deployTapoutFixture);

      const gameConfig = await tapout.getGameConfig();
      expect(gameConfig.token).to.equal(gameTokenAddress);
      expect(gameConfig.duration).to.equal(baseDuration);
      expect(gameConfig.baseCost).to.equal(baseTapCost);
      expect(gameConfig.increasePercent).to.equal(tapCostIncreasePercent);
      expect(gameConfig.active).to.be.true;
      expect(gameConfig.fee).to.equal(choiceFee);

      const round = await tapout.getCurrentRound();
      expect(round.roundNumber).to.equal(1n);
      expect(round.started).to.be.false;

      const { netAmount: expectedNetPrize } = calculateNetAndFee(initialPrizePool, devFeePercent);
      expect(round.prizePool).to.equal(expectedNetPrize);

      const financials = await tapout.getFinancials();
      const { ownerFee: expectedOwnerFee } = calculateNetAndFee(initialPrizePool, devFeePercent);
      expect(financials.ownerFees).to.equal(expectedOwnerFee);
    });

    it("Should reject reinitialization", async function () {
      const { tapout, gameTokenAddress, baseDuration, baseTapCost, tapCostIncreasePercent, choiceFee } = await loadFixture(deployTapoutFixture);
      await expect(
        tapout.initialize(gameTokenAddress, baseDuration, baseTapCost, tapCostIncreasePercent, choiceFee)
      ).to.be.revertedWithCustomError(tapout, "AlreadyInitialized");
    });
  });

  describe("Tapping Mechanics", function () {
    it("Should update game state correctly and distribute tap cost", async function () {
      const { tapout, gameToken, player1, baseTapCost, tapoutAddress } = await loadFixture(deployTapoutFixture);
      const deadAddress = "0x000000000000000000000000000000000000dEaD";

      const initialBurnBalance = await gameToken.balanceOf(deadAddress);
      const initialContractTokenBalance = await gameToken.balanceOf(tapoutAddress);

      await tapout.connect(player1).tap();

      const round = await tapout.getCurrentRound();
      expect(round.tapper).to.equal(player1.address);
      expect(round.taps).to.equal(1n);
      expect(round.started).to.be.true;
      expect(round.endTime).to.be.gt(0n);

      const playerStats = await tapout.getPlayerStats(player1.address);
      expect(playerStats.tapCount).to.equal(1n);

      const toPool = baseTapCost / 2n;
      const toBurn = baseTapCost - toPool;

      const finalBurnBalance = await gameToken.balanceOf(deadAddress);
      const finalContractTokenBalance = await gameToken.balanceOf(tapoutAddress);

      expect(finalBurnBalance).to.equal(initialBurnBalance + toBurn);
      expect(finalContractTokenBalance).to.equal(initialContractTokenBalance + toPool);
      expect(round.tokenBonus).to.equal(toPool);
    });

    it("Should increase tap cost and decrease duration after each tap", async function () {
      const { tapout, player1, baseTapCost, tapCostIncreasePercent, baseDuration } = await loadFixture(deployTapoutFixture);

      await tapout.connect(player1).tap();
      let round = await tapout.getCurrentRound();
      let expectedCost = baseTapCost + (baseTapCost * tapCostIncreasePercent) / 10000n;
      expect(round.tapCost).to.equal(expectedCost);
      expect(round.timeLeft).to.be.closeTo(baseDuration, 2);

      await tapout.connect(player1).tap();
      round = await tapout.getCurrentRound();
      let lastCost = expectedCost;
      expectedCost = lastCost + (lastCost * tapCostIncreasePercent) / 10000n;
      expect(round.tapCost).to.equal(expectedCost);
      const expectedDuration = baseDuration - (await tapout.TAP_DURATION_DECREASE());
      expect(round.timeLeft).to.be.closeTo(expectedDuration, 2);
    });

    it("Should allow taps from contracts", async function () {
        const { tapout, gameToken, owner, baseTapCost, tapoutAddress, gameTokenAddress, baseDuration } = await loadFixture(deployTapoutFixture);

        const RelayerFactory = await ethers.getContractFactory("TapRelayer");
        const relayer = (await RelayerFactory.connect(owner).deploy(tapoutAddress)) as TapRelayer;
        await relayer.waitForDeployment();
        const relayerAddress = await relayer.getAddress();

        await gameToken.connect(owner).transfer(relayerAddress, baseTapCost);
        await relayer.connect(owner).approveLastTap(gameTokenAddress, baseTapCost);

        //Execute the transaction first to get the block timestamp
        const tx = await relayer.connect(owner).relayTap();
        const receipt = await tx.wait();
        const block = await ethers.provider.getBlock(receipt!.blockNumber);
        const timestamp = BigInt(block!.timestamp);

        // The new end time is the block's timestamp plus the base duration for the first tap
        const expectedEndTime = timestamp + baseDuration;

        // Now assert the event with the correct, predictable values
        await expect(tx)
            .to.emit(tapout, "Tapped")
            .withArgs(1n, relayerAddress, baseTapCost, expectedEndTime, timestamp);

        const round = await tapout.getCurrentRound();
        expect(round.tapper).to.equal(relayerAddress);
    });

    it("Should reject taps with insufficient tokens or allowance", async function () {
      const { tapout, gameToken, otherPlayer, tapoutAddress } = await loadFixture(deployTapoutFixture);
      const poorPlayer = (await ethers.getSigners())[5];

      await expect(tapout.connect(poorPlayer).tap()).to.be.revertedWithCustomError(tapout, "InsufficientTokens");

      await gameToken.connect(otherPlayer).approve(tapoutAddress, 0);
      await expect(tapout.connect(otherPlayer).tap()).to.be.revertedWithCustomError(tapout, "InsufficientAllowance");
    });
  });

  describe("Round Transitions and Auto-Distribution", function () {
    it("Should end round, auto-distribute ETH prize, and start a new one", async function () {
      const { tapout, player1, player2, initialPrizePool, devFeePercent } = await loadFixture(deployTapoutFixture);
      const { netAmount: expectedPrize } = calculateNetAndFee(initialPrizePool, devFeePercent);

      await tapout.connect(player1).tap();
      const p1BalanceBeforeWin = await ethers.provider.getBalance(player1.address);

      const round1EndTime = (await tapout.getCurrentRound()).endTime;
      await time.increaseTo(round1EndTime + 1n);

      await tapout.connect(player2).tap();

      const [winner1, prize1] = await tapout.getRoundHistory(1);
      expect(winner1).to.equal(player1.address);
      expect(prize1).to.equal(expectedPrize);

      const p1BalanceAfterWin = await ethers.provider.getBalance(player1.address);
      expect(p1BalanceAfterWin).to.equal(p1BalanceBeforeWin + expectedPrize);

      const newRound = await tapout.getCurrentRound();
      expect(newRound.roundNumber).to.equal(2n);
      expect(newRound.tapper).to.equal(player2.address);
      expect(newRound.taps).to.equal(1n);
    });

    it("Should reset round parameters for the new round", async function () {
        const { tapout, player1, player2, baseDuration, baseTapCost, tapCostIncreasePercent } = await loadFixture(deployTapoutFixture);

        await tapout.connect(player1).tap();
        await tapout.connect(player1).tap();
        const roundBeforeEnd = await tapout.getCurrentRound();
        expect(roundBeforeEnd.tapCost).to.not.equal(baseTapCost);
        expect(roundBeforeEnd.timeLeft).to.be.lt(baseDuration);

        await time.increaseTo(roundBeforeEnd.endTime + 1n);
        await tapout.connect(player2).tap();

        const newRound = await tapout.getCurrentRound();
        expect(newRound.roundNumber).to.equal(2n);
        expect(newRound.timeLeft).to.be.closeTo(baseDuration, 2);
        expect(newRound.taps).to.equal(1n);

        const expectedNextTapCost = baseTapCost + (baseTapCost * tapCostIncreasePercent) / 10000n;
        expect(newRound.tapCost).to.equal(expectedNextTapCost);
    });
  });

  describe("Choose Winner and Prize Claiming", function () {
    it("Should allow players to choose a winner and pay the fee", async function () {
        const { tapout, player1, player2, choiceFee } = await loadFixture(deployTapoutFixture);

        const initialBonus = (await tapout.getCurrentRound()).tokenBonus;
        await tapout.connect(player1).chooseWinner(player2.address);

        const [choice, claimed] = await tapout.getPlayerChoice(1, player1.address);
        expect(choice).to.equal(player2.address);
        expect(claimed).to.be.false;

        const round = await tapout.getCurrentRound();
        expect(round.tokenBonus).to.equal(initialBonus + choiceFee);
    });

    it("Should correctly distribute token prizes to correct choosers", async function () {
        const { tapout, gameToken, player1, player2, player3, otherPlayer, choiceFee, baseTapCost } = await loadFixture(deployTapoutFixture);

        await tapout.connect(player1).chooseWinner(player3.address);
        await tapout.connect(player2).chooseWinner(player3.address);
        await tapout.connect(otherPlayer).chooseWinner(player1.address);

        await tapout.connect(player3).tap();

        const totalTokenPrize = (await tapout.getCurrentRound()).tokenBonus;

        await time.increaseTo((await tapout.getCurrentRound()).endTime + 1n);
        await tapout.connect(otherPlayer).tap();

        const expectedWinningsPerPlayer = totalTokenPrize / 2n;

        const p1BalanceBefore = await gameToken.balanceOf(player1.address);
        await tapout.connect(player1).claimTokenWinnings([1]);
        const p1BalanceAfter = await gameToken.balanceOf(player1.address);
        expect(p1BalanceAfter).to.equal(p1BalanceBefore + expectedWinningsPerPlayer);

        const p2BalanceBefore = await gameToken.balanceOf(player2.address);
        await tapout.connect(player2).claimTokenWinnings([1]);
        const p2BalanceAfter = await gameToken.balanceOf(player2.address);
        expect(p2BalanceAfter).to.equal(p2BalanceBefore + expectedWinningsPerPlayer);

        await expect(tapout.connect(otherPlayer).claimTokenWinnings([1])).to.be.revertedWithCustomError(tapout, "NoWinningsToClaimInBatch");
    });

    it("Should roll over token prize if no one chose the winner", async function () {
        const { tapout, player1, player2, player3, choiceFee, baseTapCost } = await loadFixture(deployTapoutFixture);

        //Create a true rollover scenario. P1 chooses P2, but P3 wins.
        await tapout.connect(player1).chooseWinner(player2.address);
        await tapout.connect(player3).tap(); // P3 is the winner

        // Get the total token prize from round 1 that should be rolled over
        const tokenPrizeRound1 = (await tapout.getCurrentRound()).tokenBonus;
        expect(tokenPrizeRound1).to.equal(choiceFee + (baseTapCost / 2n));

        // End round 1, start round 2
        await time.increaseTo((await tapout.getCurrentRound()).endTime + 1n);
        await tapout.connect(player1).tap(); // P1 triggers transition

        // Round 2 should start with the rolled-over prize from R1 + P1's new tap bonus
        const round2 = await tapout.getCurrentRound();
        const tapBonusR2 = baseTapCost / 2n;
        expect(round2.tokenBonus).to.equal(tokenPrizeRound1 + tapBonusR2);
    });

    it("Should allow winner to claim ETH prize manually during limbo", async function () {
        const { tapout, player1, initialPrizePool, devFeePercent } = await loadFixture(deployTapoutFixture);
        const { netAmount: expectedPrize } = calculateNetAndFee(initialPrizePool, devFeePercent);

        await tapout.connect(player1).tap();
        const p1BalanceBefore = await ethers.provider.getBalance(player1.address);

        await time.increaseTo((await tapout.getCurrentRound()).endTime + 1n);

        const claimTx = await tapout.connect(player1).claimETHPrize(1);
        const receipt = await claimTx.wait();
        const gasCost = (receipt?.gasUsed ?? 0n) * (receipt?.gasPrice ?? 0n);

        const p1BalanceAfter = await ethers.provider.getBalance(player1.address);
        expect(p1BalanceAfter).to.equal(p1BalanceBefore + expectedPrize - gasCost);

        const round = await tapout.getCurrentRound();
        expect(round.prizePool).to.equal(0);

        //The view function shows the HISTORICAL prize amount, even after it's claimed.
        const [claimed, winner, prize] = await tapout.getETHPrizeStatus(1);
        expect(claimed).to.be.true;
        expect(winner).to.equal(player1.address);
        expect(prize).to.equal(expectedPrize);
    });

    it("Should handle claiming winnings from multiple rounds in one call", async function () {
        const { tapout, gameToken, player1, player2, player3, choiceFee, baseTapCost } = await loadFixture(deployTapoutFixture);

        // --- Round 1: P1 wins, P2 chooses P1 ---
        await tapout.connect(player2).chooseWinner(player1.address);
        await tapout.connect(player1).tap(); // P1 wins
        const r1TokenPrize = (await tapout.getCurrentRound()).tokenBonus;
        await time.increaseTo((await tapout.getCurrentRound()).endTime + 1n);
        await tapout.connect(player3).tap(); // P3 starts R2

        // --- Round 2: P3 wins, P2 chooses P3 ---
        await tapout.connect(player2).chooseWinner(player3.address); // P2 chooses P3 for R2
        await tapout.connect(player3).tap(); // P3 taps again, now winning R2
        const r2TokenPrize = (await tapout.getCurrentRound()).tokenBonus;
        await time.increaseTo((await tapout.getCurrentRound()).endTime + 1n);
        await tapout.connect(player1).tap(); // P1 starts R3

        // P2 should have winnings from R1 and R2
        const p2BalanceBefore = await gameToken.balanceOf(player2.address);
        // Claim for both rounds in a single transaction
        await tapout.connect(player2).claimTokenWinnings([1, 2]);
        const p2BalanceAfter = await gameToken.balanceOf(player2.address);

        const totalWinnings = r1TokenPrize + r2TokenPrize;
        expect(p2BalanceAfter).to.equal(p2BalanceBefore + totalWinnings);

        // Calling again for the same rounds should fail
        await expect(tapout.connect(player2).claimTokenWinnings([1, 2])).to.be.revertedWithCustomError(tapout, "NoWinningsToClaimInBatch");
    });
  });

  describe("Owner Functions and Fee Management", function () {
    it("Should accumulate owner fees correctly", async function () {
      const { tapout, owner, devFeePercent, tapoutAddress } = await loadFixture(deployTapoutFixture);
      const initialFees = (await tapout.getFinancials()).ownerFees;

      const fundAmount = ethers.parseEther("2.0");
      const { ownerFee: additionalFee } = calculateNetAndFee(fundAmount, devFeePercent);

      await owner.sendTransaction({ to: tapoutAddress, value: fundAmount });

      const finalFees = (await tapout.getFinancials()).ownerFees;
      expect(finalFees).to.equal(initialFees + additionalFee);
    });

    it("Should allow owner to withdraw accumulated fees", async function () {
      const { tapout, owner } = await loadFixture(deployTapoutFixture);
      const feesToWithdraw = (await tapout.getFinancials()).ownerFees;
      expect(feesToWithdraw).to.be.gt(0);

      const ownerBalanceBefore = await ethers.provider.getBalance(owner.address);
      const tx = await tapout.connect(owner).withdrawOwnerFees();
      const receipt = await tx.wait();
      const gasCost = (receipt?.gasUsed ?? 0n) * (receipt?.gasPrice ?? 0n);

      const ownerBalanceAfter = await ethers.provider.getBalance(owner.address);
      expect(ownerBalanceAfter).to.equal(ownerBalanceBefore + feesToWithdraw - gasCost);

      const feesAfter = (await tapout.getFinancials()).ownerFees;
      expect(feesAfter).to.equal(0);
    });

    it("Should reject fee withdrawal when no fees are accumulated", async function () {
        const [owner] = await ethers.getSigners();
        const TapoutFactory = await ethers.getContractFactory("Tapout");
        const newGame = (await TapoutFactory.connect(owner).deploy()) as Tapout;
        await newGame.waitForDeployment();

        await expect(
          newGame.connect(owner).withdrawOwnerFees()
        ).to.be.revertedWithCustomError(newGame, "NothingToWithdraw");
      });

    it("Should allow owner to recover non-game ERC20 tokens", async function () {
        const { tapout, owner, tapoutAddress } = await loadFixture(deployTapoutFixture);
        const RecoverableTokenFactory = await ethers.getContractFactory("MockERC20");
        const recoverableToken = await RecoverableTokenFactory.deploy("Recover", "REC", ethers.parseEther("1000"), 18);
        await recoverableToken.waitForDeployment();
        const recoveryAmount = ethers.parseEther("50");
        await recoverableToken.transfer(tapoutAddress, recoveryAmount);

        const ownerBalanceBefore = await recoverableToken.balanceOf(owner.address);
        await tapout.connect(owner).emergencyTokenWithdraw(await recoverableToken.getAddress(), recoveryAmount);
        const ownerBalanceAfter = await recoverableToken.balanceOf(owner.address);

        expect(ownerBalanceAfter).to.equal(ownerBalanceBefore + recoveryAmount);
    });

    it("Should prevent withdrawal of the game's payment token", async function () {
        const { tapout, owner, gameTokenAddress } = await loadFixture(deployTapoutFixture);
        await expect(
            tapout.connect(owner).emergencyTokenWithdraw(gameTokenAddress, 10)
        ).to.be.revertedWithCustomError(tapout, "CannotWithdrawGameToken");
    });
  });
});