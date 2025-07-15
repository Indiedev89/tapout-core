// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title TapToken
 * @author RebaseRicky
 * @notice An ERC20 token designed for the Tapout game ecosystem. It features a transaction fee mechanism
 * that collects tokens on buys and sells, swaps them for ETH, and distributes the ETH to treasury,
 * game, and staking contracts.
 */
contract TapToken is ERC20, Ownable {

    /**
     * @dev Packs boolean flags together to save storage slots.
     * @param tradingActive True if public trading is enabled.
     * @param swapEnabled True if the automatic swap-and-distribute mechanism is active.
     * @param preMigrationPhase True if the token is in the pre-launch phase where only whitelisted addresses can transfer.
     * @param inSwap Re-entrancy guard for the `swapBack` function.
     * @param swapping A flag to prevent fee collection during a swap operation.
     */
    struct FeatureFlags {
        bool tradingActive;
        bool swapEnabled;
        bool preMigrationPhase;
        bool inSwap;
        bool swapping;
    }

    // ======= STATE VARIABLES =======

    // --- Uniswap Configuration ---
    /// @notice The Uniswap V2 router used for swapping tokens for ETH.
    IUniswapV2Router02 public uniswapV2Router;
    /// @notice The address of the official Uniswap V2 pair for this token and WETH.
    address public uniswapV2Pair;
    /// @notice An authorized address (e.g., the game contract) that can trigger a manual swap besides the owner.
    address public authorizedSwapCaller;

    // --- Recipient Addresses ---
    /// @notice The wallet address that receives the treasury portion of the collected fees.
    address public treasuryWallet;
    /// @notice The game contract address that receives its portion of the collected fees.
    address public gameContract;
    /// @notice The staking contract address that receives its portion of the collected fees.
    address public stakingContract;

    // --- Swap Configuration ---
    /// @notice The minimum number of collected tokens required in the contract to trigger an automatic swap and distribution.
    uint256 public swapTokensAtAmount;
    /// @notice A multiplier on `swapTokensAtAmount` to cap the maximum number of tokens swapped in a single transaction, preventing excessive price impact.
    uint256 public maxSwapMultiplier = 10;

    // --- Feature Flags ---
    /// @dev Holds all the boolean feature flags for the contract in a packed struct.
    FeatureFlags private _flags;

    // --- Mappings ---
    /// @notice A mapping of addresses that are blacklisted (e.g., malicious liquidity pools). Transfers involving these addresses will be reverted.
    mapping(address => bool) public blacklistedPools;
    /// @notice A mapping of addresses that are excluded from transaction fees.
    mapping(address => bool) private _isExcludedFromFees;
    /// @notice A mapping to identify addresses as Automated Market Maker (AMM) pairs. Transfers to/from these pairs are considered buys/sells.
    mapping(address => bool) public automatedMarketMakerPairs;
    /// @notice A mapping of addresses that are authorized to transfer tokens during the pre-migration phase.
    mapping(address => bool) public preMigrationTransferrable;

    // --- Fee Structure ---
    /// @notice The portion of buy fees allocated to the treasury, in basis points (100 = 1%).
    uint16 public buyTreasuryFee;
    /// @notice The portion of buy fees allocated to the game contract, in basis points.
    uint16 public buyGameFee;
    /// @notice The portion of buy fees allocated to the staking contract, in basis points.
    uint16 public buyStakingFee;
    /// @notice The total fee for buy transactions, in basis points.
    uint16 public buyTotalFees;

    /// @notice The portion of sell fees allocated to the treasury, in basis points.
    uint16 public sellTreasuryFee;
    /// @notice The portion of sell fees allocated to the game contract, in basis points.
    uint16 public sellGameFee;
    /// @notice The portion of sell fees allocated to the staking contract, in basis points.
    uint16 public sellStakingFee;
    /// @notice The total fee for sell transactions, in basis points.
    uint16 public sellTotalFees;

    // --- Fee Collection State ---
    /// @notice The number of collected tokens waiting to be swapped and sent to the treasury.
    uint256 public tokensForTreasury;
    /// @notice The number of collected tokens waiting to be swapped and sent to the game contract.
    uint256 public tokensForGame;
    /// @notice The number of collected tokens waiting to be swapped and sent to the staking contract.
    uint256 public tokensForStaking;

    // --- Constants ---
    /// @dev The maximum total fee (buy or sell) allowed, in basis points (500 = 5%).
    uint16 private constant MAX_FEE = 500;
    /// @dev The denominator used for calculating fees from basis points.
    uint16 private constant FEE_DENOMINATOR = 10000;

    // ======= MODIFIERS =======

    /**
     * @dev A re-entrancy guard to prevent multiple simultaneous calls to the `swapBack` function.
     */
    modifier lockTheSwap() {
        if (_flags.inSwap) revert();
        _flags.inSwap = true;
        _;
        _flags.inSwap = false;
    }

    /**
     * @dev A modifier to restrict a function's access to the owner or the authorized swap caller.
     */
    modifier canTriggerSwap() {
        if (msg.sender != owner() && msg.sender != authorizedSwapCaller) revert UnauthorizedSwapCaller();
        _;
    }

    // ======= EVENTS =======

    /// @notice Emitted when the Uniswap V2 router address is updated.
    /// @param newAddress The new router address.
    event UpdateUniswapV2Router(address indexed newAddress);
    /// @notice Emitted when an account's fee exclusion status is changed.
    /// @param account The account address.
    /// @param isExcluded True if the account is now excluded from fees.
    event ExcludeFromFees(address indexed account, bool isExcluded);
    /// @notice Emitted when an address is marked as an AMM pair.
    /// @param pair The pair address.
    /// @param value True if the address is an AMM pair.
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    /// @notice Emitted when the treasury wallet address is updated.
    /// @param newAddress The new treasury wallet address.
    event TreasuryWalletUpdated(address indexed newAddress);
    /// @notice Emitted when the game contract address is updated.
    /// @param newGameContract The new game contract address.
    event GameContractUpdated(address indexed newGameContract);
    /// @notice Emitted when the staking contract address is updated.
    /// @param newStakingContract The new staking contract address.
    event StakingContractUpdated(address indexed newStakingContract);
    /// @notice Emitted when trading is enabled for the public.
    /// @param timestamp The block timestamp when trading was enabled.
    event TradingEnabled(uint256 timestamp);
    /// @notice Emitted when a liquidity pool's blacklist status is changed.
    /// @param pool The address of the pool.
    /// @param blacklisted True if the pool is now blacklisted.
    event PoolBlacklistStatusChanged(address indexed pool, bool blacklisted);
    /// @notice Emitted when an account's ability to transfer during pre-migration is changed.
    /// @param account The account address.
    /// @param isTransferable True if the account can now transfer.
    event PreMigrationTransferableSet(address indexed account, bool isTransferable);
    /// @notice Emitted when buy or sell fees are updated.
    /// @param feeType "Buy" or "Sell".
    /// @param treasuryFee The new treasury fee in basis points.
    /// @param gameFee The new game fee in basis points.
    /// @param stakingFee The new staking fee in basis points.
    /// @param totalFees The new total fees in basis points.
    event FeeUpdated(string feeType, uint16 treasuryFee, uint16 gameFee, uint16 stakingFee, uint16 totalFees);
    /// @notice Emitted when collected tokens are successfully swapped for ETH.
    /// @param tokensSwapped The amount of tokens that were swapped.
    /// @param ethReceived The amount of ETH received from the swap.
    event TokensSwapped(uint256 tokensSwapped, uint256 ethReceived);
    /// @notice Emitted when non-native ERC20 tokens are recovered from the contract.
    /// @param token The address of the recovered token.
    /// @param to The recipient of the recovered tokens.
    /// @param amount The amount of tokens recovered.
    event TokensRecovered(address token, address to, uint256 amount);
    /// @notice Emitted when ETH is recovered from the contract.
    /// @param to The recipient of the recovered ETH.
    /// @param amount The amount of ETH recovered.
    event EthRecovered(address to, uint256 amount);
    /// @notice Emitted when the manual swap function is triggered.
    /// @param tokenAmount The amount of tokens in the contract at the time of the swap.
    /// @param timestamp The block timestamp of the event.
    event ManualSwapTriggered(uint256 tokenAmount, uint256 timestamp);
    /// @notice Emitted when the authorized swap caller address is updated.
    /// @param newCaller The new authorized caller address.
    event AuthorizedSwapCallerUpdated(address indexed newCaller);

    // ======= ERRORS =======
    /// @notice Reverted when a provided address is the zero address.
    error ZeroAddress();
    /// @notice Reverted when a provided address is invalid for the context (e.g., a router with no factory).
    /// @param invalidAddress The address that was deemed invalid.
    error InvalidAddress(address invalidAddress);
    /// @notice Reverted when a transfer is attempted before trading is enabled.
    error TradingNotActive();
    /// @notice Reverted when a transfer involves a blacklisted liquidity pool.
    /// @param pool The address of the blacklisted pool.
    error BlacklistedPool(address pool);
    /// @notice Reverted when an unauthorized address attempts to transfer during the pre-migration phase.
    error UnauthorizedPreMigration();
    /// @notice Reverted when an action is attempted on a protected address (e.g., the main Uniswap pair).
    /// @param protectedAddress The address that is protected from the action.
    error ProtectedAddress(address protectedAddress);
    /// @notice Reverted when setting a swap amount that is outside the allowed range.
    /// @param provided The amount that was provided.
    /// @param minLimit The minimum allowed amount.
    /// @param maxLimit The maximum allowed amount.
    error SwapAmountOutOfRange(uint256 provided, uint256 minLimit, uint256 maxLimit);
    /// @notice Reverted when setting fees that exceed the maximum allowed limit.
    /// @param totalFee The total fee that was attempted to be set.
    /// @param maxAllowed The maximum fee allowed.
    error FeeExceedsLimit(uint256 totalFee, uint256 maxAllowed);
    /// @notice Reverted when a provided multiplier is outside the allowed range.
    /// @param provided The multiplier that was provided.
    /// @param minLimit The minimum allowed multiplier.
    /// @param maxLimit The maximum allowed multiplier.
    error MultiplierOutOfRange(uint256 provided, uint256 minLimit, uint256 maxLimit);
    /// @notice Reverted when an ETH or token transfer fails.
    error TransferFailed();
    /// @notice Reverted when a function is called with an invalid amount (e.g., zero).
    error InvalidAmount(uint256 amount);
    /// @notice Reverted when a function that should only be called once is called again (e.g., enableTrading).
    error AlreadyInitialized();
    /// @notice Reverted when an invalid Uniswap router address is provided.
    error InvalidRouter();
    /// @notice Reverted when a swap is triggered but there are no tokens in the contract to swap.
    error NoTokensToSwap();
    /// @notice Reverted when a swap is attempted while another swap is already in progress.
    error SwapInProgress();
    /// @notice Reverted when an unauthorized address attempts to trigger a swap.
    error UnauthorizedSwapCaller();

    /**
     * @dev Sets up the contract, mints the total supply, and configures initial parameters.
     * @param _uniswapV2Router The address of the Uniswap V2 Router.
     * @param _treasuryWallet The address for the treasury.
     * @param _gameContract The address for the game contract.
     * @param _stakingContract The address for the staking contract.
     */
    constructor(
        IUniswapV2Router02 _uniswapV2Router,
        address _treasuryWallet,
        address _gameContract,
        address _stakingContract
    ) ERC20("Tap Token", "TAP") Ownable(msg.sender) {
        if (_treasuryWallet == address(0)) revert ZeroAddress();
        if (_gameContract == address(0)) revert ZeroAddress();
        if (_stakingContract == address(0)) revert ZeroAddress();
        if (address(_uniswapV2Router) == address(0)) revert ZeroAddress();

        uniswapV2Router = _uniswapV2Router;
        treasuryWallet = _treasuryWallet;
        gameContract = _gameContract;
        stakingContract = _stakingContract;
        authorizedSwapCaller = _gameContract;

        address factory = _uniswapV2Router.factory();
        if (factory == address(0)) revert InvalidRouter();

        _approve(address(this), address(uniswapV2Router), type(uint256).max);

        uniswapV2Pair = IUniswapV2Factory(factory)
            .createPair(address(this), _uniswapV2Router.WETH());
        _setAutomatedMarketMakerPair(address(uniswapV2Pair), true);

        // Set initial fee structure (in basis points: 100 = 1%)
        buyTreasuryFee = 100;  // 1%
        buyGameFee = 300;      // 3%
        buyStakingFee = 100;   // 1%
        buyTotalFees = buyTreasuryFee + buyGameFee + buyStakingFee;

        sellTreasuryFee = 100; // 1%
        sellGameFee = 300;     // 3%
        sellStakingFee = 100;  // 1%
        sellTotalFees = sellTreasuryFee + sellGameFee + sellStakingFee;

        _flags.preMigrationPhase = true;

        uint256 totalSupply = 1_000_000_000 * 1e18; // 1 billion tokens
        swapTokensAtAmount = (totalSupply * 5) / 10000; // 0.05% of total supply

        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        excludeFromFees(address(0xdead), true);
        excludeFromFees(_gameContract, true);
        excludeFromFees(_stakingContract, true);

        preMigrationTransferrable[owner()] = true;
        preMigrationTransferrable[address(this)] = true;
        preMigrationTransferrable[address(_gameContract)] = true;
        preMigrationTransferrable[address(_stakingContract)] = true;

        _mint(msg.sender, totalSupply);
    }

    /**
     * @dev Fallback function to allow the contract to receive ETH from the Uniswap router during swaps.
     */
    receive() external payable {}

    // ======= VIEW FUNCTIONS =======

    /**
     * @notice Checks if public trading is currently active.
     * @return True if trading is active, false otherwise.
     */
    function isTradingActive() external view returns (bool) {
        return _flags.tradingActive;
    }

    /**
     * @notice Checks if the automatic token swap mechanism is enabled.
     * @return True if swapping is enabled, false otherwise.
     */
    function isSwapEnabled() external view returns (bool) {
        return _flags.swapEnabled;
    }

    /**
     * @notice Checks if the contract is currently in the pre-migration phase.
     * @return True if in pre-migration, false otherwise.
     */
    function isPreMigrationPhase() external view returns (bool) {
        return _flags.preMigrationPhase;
    }

    /**
     * @notice Checks if a given address is excluded from transaction fees.
     * @param account The address to check.
     * @return True if the address is excluded from fees.
     */
    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    // ======= OWNER FUNCTIONS =======

    /**
     * @notice Enables public trading, ends the pre-migration phase, and enables the swap mechanism.
     * @dev Can only be called once by the owner.
     */
    function enableTrading() external onlyOwner {
        if (_flags.tradingActive) revert AlreadyInitialized();

        _flags.tradingActive = true;
        _flags.swapEnabled = true;
        _flags.preMigrationPhase = false;

        emit TradingEnabled(block.timestamp);
    }

    /**
     * @notice Updates the multiplier used to cap the maximum number of tokens swapped in a single transaction.
     * @param newMultiplier The new multiplier, must be between 0 and 30.
     */
    function updateMaxSwapMultiplier(uint256 newMultiplier) external onlyOwner {
        if (newMultiplier > 30) revert MultiplierOutOfRange(newMultiplier, 0, 30);
        maxSwapMultiplier = newMultiplier;
    }

    /**
     * @notice Updates the threshold of collected tokens that triggers an automatic swap.
     * @param newAmount The new threshold amount, must be within a safe range of total supply.
     * @return success Boolean indicating success.
     */
    function updateSwapTokensAtAmount(uint256 newAmount)
        external
        onlyOwner
        returns (bool)
    {
        uint256 minLimit = (totalSupply() * 1) / 100000; // 0.001%
        uint256 maxLimit = (totalSupply() * 5) / 1000;   // 0.5%

        if (newAmount < minLimit || newAmount > maxLimit) {
            revert SwapAmountOutOfRange(newAmount, minLimit, maxLimit);
        }

        swapTokensAtAmount = newAmount;
        return true;
    }

    /**
     * @notice Updates the fees applied to buy transactions.
     * @param _treasuryFee New treasury fee in basis points.
     * @param _gameFee New game fee in basis points.
     * @param _stakingFee New staking fee in basis points.
     */
    function updateBuyFees(
        uint16 _treasuryFee,
        uint16 _gameFee,
        uint16 _stakingFee
    ) external onlyOwner {
        uint16 newTotalFees = _treasuryFee + _gameFee + _stakingFee;
        if (newTotalFees > MAX_FEE) revert FeeExceedsLimit(newTotalFees, MAX_FEE);

        buyTreasuryFee = _treasuryFee;
        buyGameFee = _gameFee;
        buyStakingFee = _stakingFee;
        buyTotalFees = newTotalFees;

        emit FeeUpdated("Buy", _treasuryFee, _gameFee, _stakingFee, newTotalFees);
    }

    /**
     * @notice Updates the fees applied to sell transactions.
     * @param _treasuryFee New treasury fee in basis points.
     * @param _gameFee New game fee in basis points.
     * @param _stakingFee New staking fee in basis points.
     */
    function updateSellFees(
        uint16 _treasuryFee,
        uint16 _gameFee,
        uint16 _stakingFee
    ) external onlyOwner {
        uint16 newTotalFees = _treasuryFee + _gameFee + _stakingFee;
        if (newTotalFees > MAX_FEE) revert FeeExceedsLimit(newTotalFees, MAX_FEE);

        sellTreasuryFee = _treasuryFee;
        sellGameFee = _gameFee;
        sellStakingFee = _stakingFee;
        sellTotalFees = newTotalFees;

        emit FeeUpdated("Sell", _treasuryFee, _gameFee, _stakingFee, newTotalFees);
    }

    /**
     * @notice Excludes or includes an address from transaction fees.
     * @param account Address to configure.
     * @param excluded True to exclude, false to include.
     */
    function excludeFromFees(address account, bool excluded) public onlyOwner {
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    /**
     * @notice Marks or unmarks an address as an AMM pair.
     * @dev The main Uniswap V2 pair for this token is protected and cannot be changed via this function.
     * @param pair The pair address to configure.
     * @param value True to mark as an AMM pair, false to unmark.
     */
    function setAutomatedMarketMakerPair(address pair, bool value)
        public
        onlyOwner
    {
        if (pair == uniswapV2Pair) {
            revert ProtectedAddress(pair);
        }

        _setAutomatedMarketMakerPair(pair, value);
    }

    /**
     * @dev Internal helper to set AMM pairs and emit the corresponding event.
     * @param pair The pair address.
     * @param value Whether it's an AMM pair.
     */
    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    /**
     * @notice Updates the Uniswap V2 router address.
     * @dev This is an emergency function. It will attempt to create and set a new Uniswap pair with the new router.
     * @param _uniswapV2Router The new router address.
     */
    function updateUniswapV2Router(IUniswapV2Router02 _uniswapV2Router) external onlyOwner {
        if (address(_uniswapV2Router) == address(0)) revert ZeroAddress();

        try _uniswapV2Router.factory() returns (address factory) {
            if (factory == address(0)) revert InvalidAddress(address(_uniswapV2Router));

            emit UpdateUniswapV2Router(address(_uniswapV2Router));
            uniswapV2Router = _uniswapV2Router;

            address oldPair = uniswapV2Pair;
            uniswapV2Pair = IUniswapV2Factory(factory).createPair(address(this), _uniswapV2Router.WETH());

            if (oldPair != uniswapV2Pair) {
                _setAutomatedMarketMakerPair(uniswapV2Pair, true);
            }
        } catch {
            revert InvalidRouter();
        }
    }

    /**
     * @notice Updates the treasury wallet address.
     * @param newAddress The new treasury wallet address.
     */
    function updateTreasuryWallet(address newAddress) external onlyOwner {
        if (newAddress == address(0)) revert ZeroAddress();
        treasuryWallet = newAddress;
        emit TreasuryWalletUpdated(newAddress);
    }

    /**
     * @notice Updates the game contract address.
     * @param newGameContract The new game contract address.
     */
    function updateGameContract(address newGameContract) external onlyOwner {
        if (newGameContract == address(0)) revert ZeroAddress();
        gameContract = newGameContract;
        emit GameContractUpdated(newGameContract);
    }

    /**
     * @notice Updates the staking contract address.
     * @param newStakingContract The new staking contract address.
     */
    function updateStakingContract(address newStakingContract) external onlyOwner {
        if (newStakingContract == address(0)) revert ZeroAddress();
        stakingContract = newStakingContract;
        emit StakingContractUpdated(newStakingContract);
    }

    /**
     * @notice Blacklists a liquidity pool address to prevent interactions.
     * @param lpAddress The liquidity pool address to blacklist.
     */
    function blacklistLiquidityPool(address lpAddress) public onlyOwner {
        if (lpAddress == address(uniswapV2Pair) || lpAddress == address(uniswapV2Router)) {
            revert ProtectedAddress(lpAddress);
        }

        blacklistedPools[lpAddress] = true;
        emit PoolBlacklistStatusChanged(lpAddress, true);
    }

    /**
     * @notice Removes a liquidity pool from the blacklist.
     * @param lpAddress The pool address to unblacklist.
     */
    function unblacklistLiquidityPool(address lpAddress) public onlyOwner {
        blacklistedPools[lpAddress] = false;
        emit PoolBlacklistStatusChanged(lpAddress, false);
    }

    /**
     * @notice Sets or revokes an address's ability to transfer tokens during the pre-migration phase.
     * @param _addr Address to configure.
     * @param isAuthorized True to authorize, false to revoke.
     */
    function setPreMigrationTransferable(address _addr, bool isAuthorized) public onlyOwner {
        preMigrationTransferrable[_addr] = isAuthorized;
        emit PreMigrationTransferableSet(_addr, isAuthorized);
    }

    /**
     * @notice Updates the address authorized to trigger manual swaps.
     * @param _caller The new authorized address.
     */
    function setAuthorizedSwapCaller(address _caller) external onlyOwner {
        authorizedSwapCaller = _caller;
        emit AuthorizedSwapCallerUpdated(_caller);
    }

    /**
     * @notice Manually triggers the swap and distribution of all collected fee tokens.
     * @dev Can be called by the owner or the authorized swap caller. Useful for manual control.
     */
    function manualSwap() external canTriggerSwap {
        uint256 contractBalance = balanceOf(address(this));
        if (contractBalance == 0) revert NoTokensToSwap();
        if (_flags.swapping) revert SwapInProgress();

        _flags.swapping = true;
        swapBack();
        _flags.swapping = false;

        emit ManualSwapTriggered(contractBalance, block.timestamp);
    }

    // ======= CORE LOGIC =======

    /**
     * @dev Overrides the internal `_update` function from OpenZeppelin's ERC20 contract to inject custom logic.
     * This function is called on every transfer, mint, and burn. It handles fee collection and triggers the automatic swap mechanism.
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from == address(0) || to == address(0)) { // Mint or Burn
            super._update(from, to, amount);
            return;
        }

        if (blacklistedPools[from] || blacklistedPools[to]) {
            revert BlacklistedPool(blacklistedPools[from] ? from : to);
        }

        if (_flags.preMigrationPhase) {
            if (!preMigrationTransferrable[from] && !preMigrationTransferrable[to]) {
                revert UnauthorizedPreMigration();
            }
        }

        if (amount == 0) {
            super._update(from, to, amount);
            return;
        }

        if (!_flags.tradingActive && !_flags.preMigrationPhase) {
            if (!_isExcludedFromFees[from] && !_isExcludedFromFees[to]) {
                revert TradingNotActive();
            }
        }

        uint256 contractTokenBalance = balanceOf(address(this));
        bool canSwap = contractTokenBalance >= swapTokensAtAmount;
        bool isBuying = automatedMarketMakerPairs[from];

        if (
            canSwap &&
            _flags.swapEnabled &&
            !_flags.swapping &&
            !isBuying &&
            !_isExcludedFromFees[from] &&
            !_isExcludedFromFees[to]
        ) {
            _flags.swapping = true;
            swapBack();
            _flags.swapping = false;
        }

        bool isSelling = automatedMarketMakerPairs[to];
        bool shouldTakeFee = (isBuying || isSelling) &&
                           !_flags.swapping &&
                           !(_isExcludedFromFees[from] && _isExcludedFromFees[to]);

        if (shouldTakeFee) {
            uint256 fees = _calculateAndDistributeFees(amount, isSelling);
            if (fees > 0) {
                super._update(from, address(this), fees);
                amount -= fees;
            }
        }

        super._update(from, to, amount);
    }

    /**
     * @dev Calculates fees for a transaction and updates the pending fee balances.
     * @param amount The transaction amount to calculate fees from.
     * @param isSell True if it's a sell transaction, false for a buy.
     * @return The total fee amount in tokens.
     */
    function _calculateAndDistributeFees(uint256 amount, bool isSell) private returns (uint256) {
        uint16 totalFees;
        uint256 fees;

        if (isSell && sellTotalFees > 0) {
            totalFees = sellTotalFees;
            fees = (amount * totalFees) / FEE_DENOMINATOR;
            if (fees > 0) {
                tokensForTreasury += (fees * sellTreasuryFee) / totalFees;
                tokensForGame += (fees * sellGameFee) / totalFees;
                tokensForStaking += (fees * sellStakingFee) / totalFees;
            }
        } else if (!isSell && buyTotalFees > 0) {
            totalFees = buyTotalFees;
            fees = (amount * totalFees) / FEE_DENOMINATOR;
            if (fees > 0) {
                tokensForTreasury += (fees * buyTreasuryFee) / totalFees;
                tokensForGame += (fees * buyGameFee) / totalFees;
                tokensForStaking += (fees * buyStakingFee) / totalFees;
            }
        }
        return fees;
    }

    /**
     * @dev Swaps a specified amount of this contract's tokens for ETH.
     * @param tokenAmount The amount of tokens to swap.
     * @return ethReceived The amount of ETH received from the swap.
     */
    function swapTokensForEth(uint256 tokenAmount) private returns (uint256 ethReceived) {
        uint256 initialETHBalance = address(this).balance;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        // No need to re-approve if approved max in constructor
        // _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );

        return address(this).balance - initialETHBalance;
    }

    /**
     * @dev Core internal function to swap collected fee tokens for ETH and distribute the ETH to the designated wallets.
     */
    function swapBack() private lockTheSwap {
        uint256 contractBalance = balanceOf(address(this));
        uint256 totalTokensToSwap = tokensForTreasury + tokensForGame + tokensForStaking;

        if (contractBalance == 0 || totalTokensToSwap == 0) {
            return;
        }

        uint256 amountToSwap = totalTokensToSwap;
        uint256 maxSwapAmount = swapTokensAtAmount * maxSwapMultiplier;
        if (amountToSwap > maxSwapAmount && maxSwapAmount > 0) {
            amountToSwap = maxSwapAmount;
        }
        if (amountToSwap > contractBalance) {
            amountToSwap = contractBalance;
        }

        uint256 ethReceived = swapTokensForEth(amountToSwap);

        if (ethReceived > 0) {
            uint256 ethForTreasury = (ethReceived * tokensForTreasury) / totalTokensToSwap;
            uint256 ethForGame = (ethReceived * tokensForGame) / totalTokensToSwap;
            uint256 ethForStaking = ethReceived - ethForTreasury - ethForGame;

            if (amountToSwap >= totalTokensToSwap) {
                tokensForTreasury = 0;
                tokensForGame = 0;
                tokensForStaking = 0;
            } else {
                uint256 swapRatio = (amountToSwap * 1e18) / totalTokensToSwap;
                tokensForTreasury -= (tokensForTreasury * swapRatio) / 1e18;
                tokensForGame -= (tokensForGame * swapRatio) / 1e18;
                tokensForStaking -= (tokensForStaking * swapRatio) / 1e18;
            }

            _safeTransferETH(treasuryWallet, ethForTreasury);
            _safeTransferETH(gameContract, ethForGame);
            _safeTransferETH(stakingContract, ethForStaking);

            emit TokensSwapped(amountToSwap, ethReceived);
        }
    }

    /**
     * @dev Internal function to safely transfer ETH with basic success checking.
     * @param to The recipient address.
     * @param amount The amount of ETH to transfer.
     */
    function _safeTransferETH(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
