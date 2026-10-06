// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITradingVenue} from "../../src/interfaces/ITradingVenue.sol";

/// @dev Funded deterministic exchange model, NOT a router implementation or a production oracle.
contract MockVenue is ITradingVenue {
    using SafeERC20 for IERC20;

    struct Rate {
        uint256 numerator;
        uint256 denominator;
        uint256 updatedAt;
    }

    mapping(bytes32 => Rate) public rates;
    uint256 public executionBps = 10_000;
    bool public underDeliver;
    bytes32 public failedPool;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    receive() external payable {}

    function key(bytes32 pool, address tokenIn, address tokenOut) public pure returns (bytes32) {
        return keccak256(abi.encode(pool, tokenIn, tokenOut));
    }

    function setRate(bytes32 pool, address tokenIn, address tokenOut, uint256 numerator, uint256 denominator) external {
        rates[key(pool, tokenIn, tokenOut)] = Rate(numerator, denominator, block.timestamp);
    }

    function setTimestamp(bytes32 pool, address tokenIn, address tokenOut, uint256 timestamp) external {
        rates[key(pool, tokenIn, tokenOut)].updatedAt = timestamp;
    }

    function configure(uint256 execution, bool underDeliver_, bytes32 failPool) external {
        executionBps = execution;
        underDeliver = underDeliver_;
        failedPool = failPool;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function quoteExactInput(bytes32 pool, address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        returns (uint256 amountOut, uint256 updatedAt)
    {
        Rate storage rate = rates[key(pool, tokenIn, tokenOut)];
        require(rate.denominator != 0, "unknown route");
        return (Math.mulDiv(amountIn, rate.numerator, rate.denominator), rate.updatedAt);
    }

    function quoteExactOutput(bytes32 pool, address tokenIn, address tokenOut, uint256 amountOut)
        public
        view
        returns (uint256 amountIn, uint256 updatedAt)
    {
        Rate storage rate = rates[key(pool, tokenIn, tokenOut)];
        require(rate.numerator != 0, "unknown route");
        return (Math.mulDiv(amountOut, rate.denominator, rate.numerator, Math.Rounding.Ceil), rate.updatedAt);
    }

    function swapExactInput(
        bytes32 pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external payable {
        require(pool != failedPool, "swap failed");
        (uint256 quoted,) = quoteExactInput(pool, tokenIn, tokenOut, amountIn);
        uint256 output = Math.mulDiv(quoted, executionBps, 10_000);
        require(output >= minOut, "slippage");
        _take(tokenIn, amountIn);
        _callback();
        _send(tokenOut, recipient, underDeliver ? output / 2 : output);
    }

    function swapExactOutput(
        bytes32 pool,
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxIn,
        address recipient
    ) external payable {
        require(pool != failedPool, "swap failed");
        (uint256 quoted,) = quoteExactOutput(pool, tokenIn, tokenOut, amountOut);
        uint256 input = Math.mulDiv(quoted, 10_000, executionBps, Math.Rounding.Ceil);
        require(input <= maxIn, "slippage");
        _take(tokenIn, input);
        _callback();
        _send(tokenOut, recipient, underDeliver ? amountOut / 2 : amountOut);
    }

    function _take(address tokenIn, uint256 input) private {
        if (tokenIn == address(0)) {
            require(msg.value >= input, "native amount");
            if (msg.value > input) _send(address(0), msg.sender, msg.value - input);
        } else {
            require(msg.value == 0, "unexpected ETH");
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), input);
        }
    }

    function _send(address asset, address recipient, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            require(ok, "native transfer");
        } else {
            IERC20(asset).safeTransfer(recipient, amount);
        }
    }

    function _callback() private {
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
    }
}
