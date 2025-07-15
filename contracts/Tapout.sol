// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Tapout
 * @author RebaseRicky
 * @notice A PvP (Player vs. Player) game where players use an ERC20 token to "tap" and reset a timer.
 */

/// @dev Interface for the specific TapToken used in the game
interface ITapToken {
    function manualSwap() external;
    function balanceOf(address account) external view returns (uint256);
    function swapTokensAtAmount() external view returns (uint256);
}

contract Tapout is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ======= CONSTANTS =======
    uint256 public constant DEV_FEE_PERCENT = 5;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MIN_ROUND_DURATION = 10 seconds;
    uint256 public constant TAP_DURATION_DECREASE = 2 seconds;
    uint256 public constant SWAP_COOLDOWN = 60 seconds;
    uint256 private constant BPS_PRECISION = 10000;

    // ======= STATE VARIABLES =======
    IERC20 public paymentToken;
    uint256 public baseDuration;
    uint256 public baseTapCost;
    uint256 public tapCostIncreasePercent;
    uint256 public choiceFee;

    bool public gameActive;
    bool public initialized;

    uint256 public lastSwapTime;
    bool public autoSwapEnabled = true;
    uint256 public swapThresholdMultiplier = 5;

    // --- Round State ---
    uint256 public currentRoundNumber;
    uint256 public roundStartTime;
    uint256 public roundEndTime;
    uint256 public currentTapCost;
    uint256 public currentDuration;
    uint256 public tapCountInRound;
    address public lastTapper;

    // --- Financial State ---
    uint256 public currentPrizePool;
    uint256 public pendingPrizePool;
    uint256 public pendingOwnerFees;

    // --- Winner Choosing State ---
    uint256 public currentTokenPrizeBonus;
    uint256 public pendingTokenPrizeBonus;
    mapping(uint256 => uint256) public roundTokenPrizeBonus;
    mapping(uint256 => mapping(address => address)) public playerChoices;
    mapping(uint256 => mapping(address => uint256)) public candidateChooserCount;
    mapping(uint256 => uint256) public totalCorrectChoosers;
    mapping(uint256 => mapping(address => bool)) public winningsClaimed;
    mapping(uint256 => mapping(address => bool)) public ethPrizeClaimed;

    // --- History & Stats ---
    uint256 public totalTaps;
    uint256 public totalTokensBurned;
    uint256 public totalPrizesAwarded;
    mapping(address => uint256) public playerTapCount;
    mapping(uint256 => address) public roundWinners;
    mapping(uint256 => uint256) public roundPrizes;

    // ======= EVENTS =======
    event GameStarted(uint256 timestamp);
    event Tapped(uint256 indexed roundNumber, address indexed player, uint256 cost, uint256 newEndTime, uint256 timestamp);
    event RoundEnded(uint256 indexed roundNumber, address indexed winner, uint256 prize, uint256 timestamp);
    event FundsAdded(address indexed sender, uint256 amount, uint256 netAmount);
    event OwnerFeesWithdrawn(uint256 amount);
    event EmergencyTokenWithdraw(address token, uint256 amount);
    event AutoSwapExecuted(uint256 tokensSwapped, uint256 timestamp);
    event AutoSwapToggled(bool enabled);
    event SwapThresholdUpdated(uint256 newMultiplier);
    event WinnerChosen(uint256 indexed roundNumber, address indexed chooser, address indexed candidate, uint256 feePaid);
    event TokenWinningsClaimed(uint256 indexed roundNumber, address indexed claimant, uint256 amount);
    event ETHPrizeClaimed(uint256 indexed roundNumber, address indexed winner, uint256 amount);
    event ChoiceFeeUpdated(uint256 newFee);

    // ======= ERRORS =======
    error GameNotActive();
    error AlreadyInitialized();
    error InvalidConfiguration();
    error InsufficientTokens();
    error InsufficientAllowance();
    error TransferFailed();
    error NothingToWithdraw();
    error CannotWithdrawGameToken();
    error RoundNotStarted();
    error InvalidChoice();
    error ChoiceAlreadyMade();
    error NothingToClaim();
    error WinningsAlreadyClaimed();
    error NoWinningsToClaimInBatch();
    error RoundNotFinalized();  // Used when trying to claim from rounds that haven't ended yet
    error NotWinner();
    error PrizeAlreadyClaimed();
    error InvalidSwapMultiplier();
    error InvalidChoiceFee(uint256 fee);

    // ======= MODIFIERS =======
    modifier onlyActive() {
        if (!gameActive) revert GameNotActive();
        _;
    }

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Initializes the game contract with configuration parameters
     * @dev Can only be called once by the owner. Sets up the initial game state.
     * @param _token The ERC20 token address used for tapping
     * @param _baseDuration The initial duration for each round in seconds
     * @param _baseCost The initial cost for the first tap in tokens
     * @param _tapCostIncreasePercent The percentage increase in tap cost per tap (in basis points)
     * @param _choiceFee The fee required to choose a potential winner
     */
    function initialize(
        address _token,
        uint256 _baseDuration,
        uint256 _baseCost,
        uint256 _tapCostIncreasePercent,
        uint256 _choiceFee
    ) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        if (_token == address(0) || _baseDuration == 0 || _baseCost == 0 ||
            _tapCostIncreasePercent == 0 || _choiceFee == 0) {
            revert InvalidConfiguration();
        }

        paymentToken = IERC20(_token);
        baseDuration = _baseDuration;
        baseTapCost = _baseCost;
        tapCostIncreasePercent = _tapCostIncreasePercent;
        choiceFee = _choiceFee;
        initialized = true;
        gameActive = true;

        _startNewRound();
        emit GameStarted(block.timestamp);
    }

    // ======= CORE GAME FUNCTIONS =======

    /**
     * @notice The main game action - allows a player to tap and become the potential winner
     * @dev This is the ONLY function that can start new rounds or end existing ones.
     *      It handles all round state transitions to maintain separation of concerns.
     *
     * Function flow:
     * 1. Check if current round has ended
     * 2. If ended, finalize it (with auto-distribution) and start a new round
     * 3. Process the tap for the active round
     * 4. Update round timer and costs
     * 5. Check for automatic token swap
     */
    function tap() external nonReentrant onlyActive {
        // CRITICAL: This is the ONLY place where rounds transition
        if (_isRoundOver()) {
            _endRoundWithAutoDistribution();
            _startNewRound();
        }

        address player = msg.sender;
        uint256 cost = currentTapCost;

        // Validate player can afford the tap
        if (paymentToken.balanceOf(player) < cost) revert InsufficientTokens();
        if (paymentToken.allowance(player, address(this)) < cost) revert InsufficientAllowance();

        // Transfer tokens and distribute
        paymentToken.safeTransferFrom(player, address(this), cost);

        uint256 toPool = cost / 2;
        uint256 toBurn = cost - toPool;

        paymentToken.safeTransfer(BURN_ADDRESS, toBurn);
        currentTokenPrizeBonus += toPool;
        totalTokensBurned += toBurn;

        // Update game state
        lastTapper = player;
        tapCountInRound++;

        // First tap of the round sets the initial timer
        if (tapCountInRound == 1) {
            roundStartTime = block.timestamp;
            currentDuration = baseDuration;
        } else {
            // Decrease duration but maintain minimum
            if (currentDuration > MIN_ROUND_DURATION + TAP_DURATION_DECREASE) {
                currentDuration -= TAP_DURATION_DECREASE;
            } else {
                currentDuration = MIN_ROUND_DURATION;
            }
        }

        roundEndTime = block.timestamp + currentDuration;

        // Increase cost for next tap
        uint256 increaseAmount = (cost * tapCostIncreasePercent) / BPS_PRECISION;
        currentTapCost = cost + increaseAmount;

        // Update statistics
        playerTapCount[player]++;
        totalTaps++;

        // Check for automatic swap
        _checkAndExecuteSwap();

        emit Tapped(currentRoundNumber, player, cost, roundEndTime, block.timestamp);
    }

    // ======= CLAIM FUNCTIONS (READ-ONLY FOR ROUND STATE) =======

    /**
     * @notice Allows the winner to claim their ETH prize
     * @dev This function supports claiming during limbo (before finalization) and after finalization.
     *      During limbo, it uses live round data. After finalization, it uses historical data.
     * @param roundNumber The round number to claim the prize for
     */
    function claimETHPrize(uint256 roundNumber) external nonReentrant {
        address winner;
        uint256 prize;

        // Check if this is the current round in limbo
        if (roundNumber == currentRoundNumber && _isRoundOver() && roundWinners[roundNumber] == address(0)) {
            // Limbo state - use live data
            winner = lastTapper;
            prize = currentPrizePool;

            if (msg.sender != winner) revert NotWinner();
            if (prize == 0) revert NothingToClaim();
            if (ethPrizeClaimed[roundNumber][msg.sender]) revert PrizeAlreadyClaimed();

            // Mark as claimed and clear the pool
            ethPrizeClaimed[roundNumber][msg.sender] = true;
            currentPrizePool = 0;

            // Record for history (partial finalization)
            roundWinners[roundNumber] = winner;
            roundPrizes[roundNumber] = prize;
            totalPrizesAwarded += prize;
        } else {
            // Finalized round - use historical data
            winner = roundWinners[roundNumber];
            if (winner == address(0)) revert RoundNotFinalized();
            if (msg.sender != winner) revert NotWinner();
            if (ethPrizeClaimed[roundNumber][msg.sender]) revert PrizeAlreadyClaimed();

            prize = roundPrizes[roundNumber];
            if (prize == 0) revert NothingToClaim();

            ethPrizeClaimed[roundNumber][msg.sender] = true;
        }

        emit ETHPrizeClaimed(roundNumber, msg.sender, prize);

        (bool success, ) = payable(msg.sender).call{value: prize}("");
        if (!success) {
            ethPrizeClaimed[roundNumber][msg.sender] = false;
            // If claiming from limbo, restore the pool
            if (roundNumber == currentRoundNumber && _isRoundOver()) {
                currentPrizePool = prize;
            }
            revert TransferFailed();
        }
    }

    /**
     * @notice Allows players to claim token winnings for correctly choosing winners
     * @dev This function supports claiming during limbo (before finalization) and after finalization.
     *      Players can claim for multiple rounds in a single transaction.
     * @param roundNumbers Array of round numbers to claim winnings for
     */
    function claimTokenWinnings(uint256[] calldata roundNumbers) external nonReentrant {
        address claimant = msg.sender;
        uint256 totalWinningsToClaim = 0;

        for (uint256 i = 0; i < roundNumbers.length; i++) {
            uint256 roundNumber = roundNumbers[i];

            // Skip if already claimed
            if (winningsClaimed[roundNumber][claimant]) continue;

            address winner;
            uint256 totalPool;
            uint256 correctChoosers;

            // Check if this is the current round in limbo
            if (roundNumber == currentRoundNumber && _isRoundOver() && roundWinners[roundNumber] == address(0)) {
                // Limbo state - use live data
                winner = lastTapper;
                totalPool = currentTokenPrizeBonus;
                correctChoosers = candidateChooserCount[roundNumber][winner];

                // If this is the first claim for this limbo round, finalize the token data
                if (roundTokenPrizeBonus[roundNumber] == 0) {
                    roundTokenPrizeBonus[roundNumber] = totalPool;
                    totalCorrectChoosers[roundNumber] = correctChoosers;
                    if (correctChoosers == 0) {
                        pendingTokenPrizeBonus += totalPool;
                        currentTokenPrizeBonus = 0;
                    }
                }
            } else {
                // Finalized round - use historical data
                winner = roundWinners[roundNumber];
                if (winner == address(0)) continue; // Skip unfinalized rounds

                totalPool = roundTokenPrizeBonus[roundNumber];
                correctChoosers = totalCorrectChoosers[roundNumber];
            }

            // Check if player chose correctly
            if (playerChoices[roundNumber][claimant] == winner && correctChoosers > 0) {
                uint256 prizeForRound = totalPool / correctChoosers;

                if (prizeForRound > 0) {
                    winningsClaimed[roundNumber][claimant] = true;
                    totalWinningsToClaim += prizeForRound;
                    emit TokenWinningsClaimed(roundNumber, claimant, prizeForRound);
                }
            }
        }

        if (totalWinningsToClaim == 0) revert NoWinningsToClaimInBatch();

        paymentToken.safeTransfer(claimant, totalWinningsToClaim);
    }

    // ======= WINNER CHOOSING FUNCTIONS =======

    /**
     * @notice Allows players to choose who they think will win a round
     * @dev Players can choose for:
     *      - The current active round (if not ended)
     *      - The next round (if current round has ended but not finalized)
     *      This allows continuous gameplay without waiting for finalization.
     * @param candidate The address of the player they predict will be the last tapper
     */
    function chooseWinner(address candidate) external nonReentrant onlyActive {
        if (candidate == address(0)) revert InvalidChoice();

        address chooser = msg.sender;
        uint256 targetRound;

        // Determine which round the choice is for
        if (_isRoundOver()) {
            // Current round has ended - choice is for the NEXT round.
            targetRound = currentRoundNumber + 1;

            // Finalize the just-ended round's token prize if it hasn't been finalized yet.
            // This handles rollover if no one chose the winner, and makes the state
            // consistent for the UI even if no one has tapped to start the next round.
            if (roundTokenPrizeBonus[currentRoundNumber] == 0) {
                address winner = lastTapper;
                uint256 correctChoosers = candidateChooserCount[currentRoundNumber][winner];

                totalCorrectChoosers[currentRoundNumber] = correctChoosers;
                roundTokenPrizeBonus[currentRoundNumber] = currentTokenPrizeBonus;

                if (correctChoosers == 0) {
                    // Rollover the prize if no one won
                    pendingTokenPrizeBonus += currentTokenPrizeBonus;
                }
                // The current pool is now finalized (either assigned to winners or rolled over).
                // It must be zeroed before we add the new choice fee to the pending pool.
                currentTokenPrizeBonus = 0;
            }
        } else {
            // Current round is still active - choice is for current round
            targetRound = currentRoundNumber;
        }

        // Check if player already made a choice for this round
        if (playerChoices[targetRound][chooser] != address(0)) revert ChoiceAlreadyMade();

        uint256 fee = choiceFee;
        if (paymentToken.balanceOf(chooser) < fee) revert InsufficientTokens();
        if (paymentToken.allowance(chooser, address(this)) < fee) revert InsufficientAllowance();

        paymentToken.safeTransferFrom(chooser, address(this), fee);

        // Add fee to appropriate pool
        if (targetRound > currentRoundNumber) {
            // Choosing for next round - fee goes to pending pool
            pendingTokenPrizeBonus += fee;
        } else {
            // Choosing for current round - fee goes to current pool
            currentTokenPrizeBonus += fee;
        }

        playerChoices[targetRound][chooser] = candidate;
        candidateChooserCount[targetRound][candidate]++;

        emit WinnerChosen(targetRound, chooser, candidate, fee);
    }

    // ======= FUND MANAGEMENT =======

    /**
     * @notice Fallback function to receive ETH and add it to the prize pool
     * @dev Automatically splits between owner fees and prize pool
     */
    receive() external payable {
        _addFunds();
    }

    // ======= OWNER FUNCTIONS =======

    /**
     * @notice Updates the fee required to choose a winner
     * @dev Only callable by owner
     * @param _newFee The new choice fee amount in tokens
     */
    function setChoiceFee(uint256 _newFee) external onlyOwner {
        if (_newFee == 0) revert InvalidChoiceFee(_newFee);
        choiceFee = _newFee;
        emit ChoiceFeeUpdated(_newFee);
    }

    /**
     * @notice Allows owner to withdraw accumulated fees
     * @dev Fees are automatically separated from prize pools
     */
    function withdrawOwnerFees() external onlyOwner {
        uint256 fees = pendingOwnerFees;
        if (fees == 0) revert NothingToWithdraw();

        pendingOwnerFees = 0;

        (bool success, ) = payable(owner()).call{value: fees}("");
        if (!success) {
            pendingOwnerFees = fees;
            revert TransferFailed();
        }

        emit OwnerFeesWithdrawn(fees);
    }

    /**
     * @notice Emergency function to withdraw non-game tokens
     * @dev Cannot withdraw the game's payment token
     * @param token The token address to withdraw
     * @param amount The amount to withdraw
     */
    function emergencyTokenWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(paymentToken)) revert CannotWithdrawGameToken();
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyTokenWithdraw(token, amount);
    }

    /**
     * @notice Toggles the automatic token swap feature
     * @dev Helps manage token liquidity if needed
     */
    function toggleAutoSwap() external onlyOwner {
        autoSwapEnabled = !autoSwapEnabled;
        emit AutoSwapToggled(autoSwapEnabled);
    }

    /**
     * @notice Updates the swap threshold multiplier
     * @dev Controls when automatic swaps are triggered
     * @param newMultiplier The new multiplier value (1-30)
     */
    function updateSwapThreshold(uint256 newMultiplier) external onlyOwner {
        if (newMultiplier == 0 || newMultiplier > 30) revert InvalidSwapMultiplier();
        swapThresholdMultiplier = newMultiplier;
        emit SwapThresholdUpdated(newMultiplier);
    }

    // ======= INTERNAL FUNCTIONS =======

    /**
     * @notice Checks if the current round has ended
     * @dev A round is over when time expires and there's been at least one tap
     * @return bool True if the round has ended
     */
    function _isRoundOver() internal view returns (bool) {
        return lastTapper != address(0) && block.timestamp >= roundEndTime;
    }

    /**
     * @notice Starts a new round with fresh state
     * @dev Moves pending pools to current pools and resets all round-specific state
     */
    function _startNewRound() internal {
        currentRoundNumber++;

        // Move pending pools to current
        currentPrizePool = pendingPrizePool;
        pendingPrizePool = 0;
        currentTokenPrizeBonus = pendingTokenPrizeBonus;
        pendingTokenPrizeBonus = 0;

        // Reset round state
        roundStartTime = 0;
        roundEndTime = 0;
        lastTapper = address(0);
        tapCountInRound = 0;
        currentTapCost = baseTapCost;
        currentDuration = baseDuration;
    }

    /**
     * @notice Finalizes the current round, records the winner, and auto-distributes ETH prize
     * @dev This is called by tap() when transitioning rounds. It handles cases where
     *      prizes may have already been claimed during limbo.
     */
    function _endRoundWithAutoDistribution() internal {
        if (lastTapper == address(0)) revert RoundNotStarted();

        address winner = lastTapper;

        // Check if already partially finalized by limbo claims
        if (roundWinners[currentRoundNumber] == address(0)) {
            // First time finalizing - record winner and prize
            uint256 ethPrize = currentPrizePool;
            roundWinners[currentRoundNumber] = winner;
            roundPrizes[currentRoundNumber] = ethPrize;
            totalPrizesAwarded += ethPrize;

            // Clear current pool
            currentPrizePool = 0;

            // Auto-distribute ETH if not already claimed
            if (!ethPrizeClaimed[currentRoundNumber][winner] && ethPrize > 0) {
                ethPrizeClaimed[currentRoundNumber][winner] = true;
                emit ETHPrizeClaimed(currentRoundNumber, winner, ethPrize);
                (bool success, ) = payable(winner).call{value: ethPrize}("");
                if (!success) {
                    ethPrizeClaimed[currentRoundNumber][winner] = false;
                    pendingPrizePool += ethPrize;
                }
            }
        }

        // Process token prize pool if not already done
        if (roundTokenPrizeBonus[currentRoundNumber] == 0) {
            uint256 correctChoosers = candidateChooserCount[currentRoundNumber][winner];
            totalCorrectChoosers[currentRoundNumber] = correctChoosers;
            roundTokenPrizeBonus[currentRoundNumber] = currentTokenPrizeBonus;

            if (correctChoosers == 0) {
                pendingTokenPrizeBonus += currentTokenPrizeBonus;
            }
            currentTokenPrizeBonus = 0;
        }

        emit RoundEnded(currentRoundNumber, winner, roundPrizes[currentRoundNumber], block.timestamp);
    }

    /**
     * @notice Processes incoming ETH and splits between fees and prize pool
     * @dev Called by receive() function and when ETH is sent to contract
     */
    function _addFunds() internal {
        uint256 amount = msg.value;
        if (amount == 0) return;

        uint256 ownerFee = (amount * DEV_FEE_PERCENT) / 100;
        uint256 netAmount = amount - ownerFee;

        pendingOwnerFees += ownerFee;

        // Add to current pool if round is active, otherwise to pending
        if (gameActive && !_isRoundOver()) {
            currentPrizePool += netAmount;
        } else {
            pendingPrizePool += netAmount;
        }

        emit FundsAdded(msg.sender, amount, netAmount);
    }

    /**
     * @notice Checks and executes automatic token swap if conditions are met
     * @dev Helps maintain token liquidity by swapping when threshold is reached
     */
    function _checkAndExecuteSwap() internal {
        if (!autoSwapEnabled) return;
        if (block.timestamp < lastSwapTime + SWAP_COOLDOWN) return;

        try ITapToken(address(paymentToken)).swapTokensAtAmount() returns (uint256 threshold) {
            uint256 contractBalance = ITapToken(address(paymentToken)).balanceOf(address(paymentToken));

            if (contractBalance >= threshold * swapThresholdMultiplier) {
                try ITapToken(address(paymentToken)).manualSwap() {
                    lastSwapTime = block.timestamp;
                    emit AutoSwapExecuted(contractBalance, block.timestamp);
                } catch {}
            }
        } catch {}
    }

    // ======= VIEW FUNCTIONS =======

    /**
     * @notice Returns the main game configuration
     * @return token Payment token address
     * @return duration Base round duration
     * @return baseCost Base tap cost
     * @return increasePercent Tap cost increase percentage
     * @return active Whether game is active
     * @return fee Choice fee amount
     */
    function getGameConfig() external view returns (
        address token,
        uint256 duration,
        uint256 baseCost,
        uint256 increasePercent,
        bool active,
        uint256 fee
    ) {
        return (
            address(paymentToken),
            baseDuration,
            baseTapCost,
            tapCostIncreasePercent,
            gameActive,
            choiceFee
        );
    }

    /**
     * @notice Returns the current round state
     * @dev Shows zeroed values for prize pool and tap cost during limbo if already claimed
     * @return roundNumber Current round number
     * @return started Whether round has started
     * @return endTime Round end timestamp
     * @return timeLeft Seconds remaining
     * @return tapper Last tapper address
     * @return prizePool Current ETH prize (0 if in limbo and claimed)
     * @return tapCost Current tap cost
     * @return taps Number of taps
     * @return tokenBonus Token prize pool
     */
    function getCurrentRound() external view returns (
        uint256 roundNumber,
        bool started,
        uint256 endTime,
        uint256 timeLeft,
        address tapper,
        uint256 prizePool,
        uint256 tapCost,
        uint256 taps,
        uint256 tokenBonus
    ) {
        // Check if we're in limbo with prizes already claimed
        bool inLimbo = _isRoundOver() && roundWinners[currentRoundNumber] == address(0);

        return (
            currentRoundNumber,
            roundStartTime > 0,
            roundEndTime,
            (roundEndTime > block.timestamp) ? roundEndTime - block.timestamp : 0,
            lastTapper,
            currentPrizePool, // Will be 0 if ETH claimed during limbo
            inLimbo ? baseTapCost : currentTapCost, // Show base cost during limbo
            tapCountInRound,
            currentTokenPrizeBonus // May be reduced if tokens claimed during limbo
        );
    }

    /**
     * @notice Returns token prize information for a specific round
     * @param roundNumber The round to query
     * @return winner Round winner address
     * @return totalPool Total token prize pool
     * @return correctChoosers Number of correct choosers
     */
    function getRoundTokenPrizeInfo(uint256 roundNumber) external view returns (
        address winner,
        uint256 totalPool,
        uint256 correctChoosers
    ) {
        return (
            roundWinners[roundNumber],
            roundTokenPrizeBonus[roundNumber],
            totalCorrectChoosers[roundNumber]
        );
    }

    /**
     * @notice Returns a player's choice and claim status for a round
     * @param roundNumber The round to query
     * @param player The player address
     * @return choice The address they chose
     * @return claimed Whether they claimed token winnings
     */
    function getPlayerChoice(uint256 roundNumber, address player) external view returns (
        address choice,
        bool claimed
    ) {
        return (
            playerChoices[roundNumber][player],
            winningsClaimed[roundNumber][player]
        );
    }

    /**
     * @notice Returns player statistics
     * @param player The player address
     * @return tapCount Total taps by player
     * @return isLastTapper Whether they're the current last tapper
     */
    function getPlayerStats(address player) external view returns (
        uint256 tapCount,
        bool isLastTapper
    ) {
        return (
            playerTapCount[player],
            player == lastTapper
        );
    }

    /**
     * @notice Returns contract financial state
     * @return currentPool Current ETH prize pool
     * @return pendingPool Pending ETH prize pool
     * @return ownerFees Pending owner fees
     * @return totalAwarded Total prizes awarded
     */
    function getFinancials() external view returns (
        uint256 currentPool,
        uint256 pendingPool,
        uint256 ownerFees,
        uint256 totalAwarded
    ) {
        return (
            currentPrizePool,
            pendingPrizePool,
            pendingOwnerFees,
            totalPrizesAwarded
        );
    }

    /**
     * @notice Returns historical round data
     * @param roundNumber The round to query
     * @return winner Round winner address
     * @return prize ETH prize amount
     */
    function getRoundHistory(uint256 roundNumber) external view returns (
        address winner,
        uint256 prize
    ) {
        return (
            roundWinners[roundNumber],
            roundPrizes[roundNumber]
        );
    }

    /**
     * @notice Comprehensive view of a player's status for a specific round
     * @dev Handles both limbo (unfinalized) and finalized rounds
     * @param roundNumber The round to query
     * @param player The player address
     * @return didWin Whether player chose correctly
     * @return canClaim Whether player can claim winnings
     * @return potentialWinnings Amount player can claim
     */
    function getPlayerRoundStatus(uint256 roundNumber, address player) external view returns (
        bool didWin,
        bool canClaim,
        uint256 potentialWinnings
    ) {
        address winner;
        uint256 totalPool;
        uint256 correctChoosers;

        // Check if this is the current round in limbo
        if (roundNumber == currentRoundNumber && _isRoundOver() && roundWinners[roundNumber] == address(0)) {
            // Limbo state - use live data
            winner = lastTapper;
            totalPool = currentTokenPrizeBonus;
            correctChoosers = candidateChooserCount[roundNumber][winner];
        } else {
            // Finalized round - use historical data
            winner = roundWinners[roundNumber];
            if (winner == address(0)) {
                return (false, false, 0); // Round not ended yet
            }
            totalPool = roundTokenPrizeBonus[roundNumber];
            correctChoosers = totalCorrectChoosers[roundNumber];
        }

        bool playerChoseWinner = playerChoices[roundNumber][player] == winner;
        didWin = playerChoseWinner;

        if (!didWin || correctChoosers == 0) {
            return (didWin, false, 0);
        }

        potentialWinnings = totalPool / correctChoosers;
        bool hasClaimed = winningsClaimed[roundNumber][player];
        canClaim = didWin && !hasClaimed && potentialWinnings > 0;

        return (didWin, canClaim, potentialWinnings);
    }

    /**
     * @notice Check if a specific round's ETH prize has been claimed
     * @dev Handles both limbo (unfinalized) and finalized rounds
     * @param roundNumber The round to check
     * @return claimed Whether the ETH prize was claimed
     * @return winner The round winner
     * @return prize The prize amount
     */
    function getETHPrizeStatus(uint256 roundNumber) external view returns (
        bool claimed,
        address winner,
        uint256 prize
    ) {
        // Check if this is the current round in limbo
        if (roundNumber == currentRoundNumber && _isRoundOver() && roundWinners[roundNumber] == address(0)) {
            // Limbo state - use live data
            winner = lastTapper;
            prize = currentPrizePool;
            claimed = ethPrizeClaimed[roundNumber][winner];
        } else {
            // Finalized round - use historical data
            winner = roundWinners[roundNumber];
            if (winner == address(0)) {
                return (false, address(0), 0);
            }
            prize = roundPrizes[roundNumber];
            claimed = ethPrizeClaimed[roundNumber][winner];
        }

        return (claimed, winner, prize);
    }
}