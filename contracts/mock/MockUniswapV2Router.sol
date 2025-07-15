// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol"; // Using Address library for safe transfer

/**
 * @title MockUniswapV2Router
 * @dev Mock implementation of Uniswap V2 Router for testing
 */
contract MockUniswapV2Router {
    using Address for address payable; // Use safe ETH transfer

    address public immutable factory;
    address public immutable WETH;
    bool public swapSuccessful;

    event SwapExactTokensForETHSupportingFeeOnTransferTokens( // Renamed event for clarity
        uint amountIn,
        uint amountOutMin,
        address[] path,
        address to,
        uint deadline
    );

    // New Event for the new function
    event SwapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] path,
        address to,
        uint deadline,
        uint amountETHIn,
        uint amountTokenOut
    );


    event AddLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    );

    /**
     * @dev Constructor for MockUniswapV2Router
     * @param _factory Address of the factory
     */
    constructor(address _factory) {
        factory = _factory;
        // Use a deterministic, but unlikely-to-collide address for WETH mock
        WETH = address(uint160(uint(keccak256(abi.encodePacked("WETH")))));
        swapSuccessful = true; // Default to successful swaps
    }

    /**
     * @dev Set whether swaps should succeed or fail
     * @param _successful Whether swaps should succeed
     */
    function setSwapSuccessful(bool _successful) external {
        swapSuccessful = _successful;
    }

    /**
     * @dev Mock implementation of swapExactTokensForETHSupportingFeeOnTransferTokens
     */
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin, // Although not used in mock calculation, keep for signature match
        address[] calldata path,
        address to,
        uint deadline // Although not used in mock calculation, keep for signature match
    ) external {
        // Basic checks similar to real router
        require(swapSuccessful, "MockRouter: Swap failed");
        require(path.length >= 2, "MockRouter: INVALID_PATH");
        require(path[path.length - 1] == WETH, "MockRouter: INVALID_PATH_WETH_OUT");
        // require(deadline >= block.timestamp, "MockRouter: EXPIRED"); // Optional deadline check

        address tokenIn = path[0];
        address intermediatePair; // For simulation consistency if needed later
        if(path.length > 2) {
            intermediatePair = path[1]; // Simulate transfer via pair if path > 2
        } else {
             intermediatePair = to; // In 2-step, first transfer is conceptually to end recipient via pair
        }

        // 1. Simulate pulling input tokens FROM msg.sender TO the router/first pair
        // Use safeTransferFrom if available, otherwise standard transferFrom
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn); // Router gets tokens first

        // 2. Simulate sending ETH TO the recipient ('to' address)
        // Mock conversion: Use a simple 1:1 or defined rate for mock testing.
        // Using 1:1 for simplicity based on the prompt asking not to use the previous rate.
        // WARNING: This 1:1 rate is purely for mock testing and NOT realistic.
        uint ethAmountOut = amountIn; // Simplified mock rate: 1 token = 1 wei ETH
        require(ethAmountOut >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");

        // Use safe ETH transfer
        payable(to).sendValue(ethAmountOut);

        emit SwapExactTokensForETHSupportingFeeOnTransferTokens(amountIn, amountOutMin, path, to, deadline);
    }

    /**
     * @dev Mock implementation of swapExactETHForTokensSupportingFeeOnTransferTokens
     * Swaps an exact amount of ETH for as many output tokens as possible.
     * IMPORTANT: Assumes this mock router contract has been pre-funded with
     * the necessary `path[path.length - 1]` tokens to perform the swap simulation.
     */
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline // Although not used in mock calculation, keep for signature match
    ) external payable returns (uint[] memory amounts) {
        // Basic checks similar to real router
        require(swapSuccessful, "MockRouter: Swap failed");
        require(path.length >= 2, "MockRouter: INVALID_PATH");
        require(path[0] == WETH, "MockRouter: INVALID_PATH_WETH_IN"); // First token must be WETH
        // require(deadline >= block.timestamp, "MockRouter: EXPIRED"); // Optional deadline check
        require(msg.value > 0, "MockRouter: INVALID_VALUE"); // Must send ETH

        // 1. ETH Received: msg.value

        // 2. Simulate Token Output Amount
        // Using 1:1 for simplicity based on the prompt asking not to use the previous rate.
        // WARNING: This 1:1 rate is purely for mock testing and NOT realistic.
        uint amountTokenOut = msg.value; // Simplified mock rate: 1 wei ETH = 1 token base unit
        require(amountTokenOut >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");

        address tokenOut = path[path.length - 1];

        // 3. Simulate sending output tokens FROM the router/last pair TO the recipient
        // This mock assumes the router holds the tokens to send.
        // In real Uniswap, the pair sends the tokens directly.
        // Use safeTransfer if available, otherwise standard transfer
        IERC20(tokenOut).transfer(to, amountTokenOut);

        // Prepare return array (amounts along the path)
        amounts = new uint[](path.length);
        amounts[0] = msg.value; // Amount of WETH (ETH) input
        amounts[amounts.length - 1] = amountTokenOut; // Amount of token output

        emit SwapExactETHForTokensSupportingFeeOnTransferTokens(
            amountOutMin,
            path,
            to,
            deadline,
            msg.value, // amountETHIn
            amountTokenOut // amountTokenOut
        );

        return amounts;
    }


    /**
     * @dev Mock implementation of addLiquidityETH
     */
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin, // Although not used in mock calculation, keep for signature match
        uint amountETHMin, // Although not used in mock calculation, keep for signature match
        address to,
        uint deadline // Although not used in mock calculation, keep for signature match
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        // require(deadline >= block.timestamp, "MockRouter: EXPIRED"); // Optional deadline check
        require(msg.value >= amountETHMin, "MockRouter: INSUFFICIENT_ETH_AMOUNT");
        require(amountTokenDesired >= amountTokenMin, "MockRouter: INSUFFICIENT_TOKEN_AMOUNT");

        // Simulate pulling tokens from sender
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);

        // Simulate ETH received (msg.value)

        // Simulate liquidity tokens calculation (highly simplified)
        // WARNING: This liquidity calculation is purely for mock testing and NOT realistic.
        liquidity = amountTokenDesired + msg.value; // Example: just add amounts

        // In a real scenario, liquidity tokens would be minted to 'to' address
        // Here we just return the simulated values.

        emit AddLiquidityETH(token, amountTokenDesired, amountTokenMin, amountETHMin, to, deadline);

        // Return the amounts used (which are the desired amounts in this simple mock)
        return (amountTokenDesired, msg.value, liquidity);
    }

    // Required to receive ETH in addLiquidityETH and swapExactETHForTokens*
    receive() external payable {}
}