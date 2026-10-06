// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILaunchRegistry} from "../interfaces/ILaunchRegistry.sol";
import {ITradingVenue} from "../interfaces/ITradingVenue.sol";

/// @dev Shared internal integration code; this is not a separately deployed application.
abstract contract Trading is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_QUOTE_AGE = 15 minutes;

    address public immutable imd;
    ILaunchRegistry public immutable registry;
    address public immutable launchFactory;
    ITradingVenue public immutable venue;
    bytes32 public immutable imdEthPoolId;
    uint256 public immutable expectedChainId;

    error InvalidConfiguration();
    error WrongChain();
    error InvalidLaunch();
    error InvalidQuote();
    error SwapAccounting();
    error NativeTransferFailed();
    error ZeroAmount();

    constructor(
        address imd_,
        address registry_,
        address launchFactory_,
        address venue_,
        bytes32 imdEthPoolId_,
        uint256 chainId_
    ) {
        if (
            imd_ == address(0) || registry_ == address(0) || launchFactory_ == address(0) || venue_ == address(0)
                || imdEthPoolId_ == bytes32(0) || chainId_ == 0
        ) revert InvalidConfiguration();
        if (block.chainid != chainId_) revert WrongChain();
        imd = imd_;
        registry = ILaunchRegistry(registry_);
        launchFactory = launchFactory_;
        venue = ITradingVenue(venue_);
        imdEthPoolId = imdEthPoolId_;
        expectedChainId = chainId_;
    }

    function _launch(address token) internal view returns (address asset, bytes32 poolId) {
        if (block.chainid != expectedChainId) revert WrongChain();
        if (token == address(0) || token == imd || token.code.length == 0) revert InvalidLaunch();
        address origin;
        (origin, asset, poolId) = registry.getLaunch(token);
        if (origin != launchFactory || (asset != imd && asset != address(0)) || poolId == bytes32(0)) {
            revert InvalidLaunch();
        }
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _quote(bytes32 pool, address tokenIn, address tokenOut, uint256 amount, bool exactOutput)
        internal
        view
        returns (uint256 quoted)
    {
        if (block.chainid != expectedChainId) revert WrongChain();
        uint256 updatedAt;
        if (exactOutput) (quoted, updatedAt) = venue.quoteExactOutput(pool, tokenIn, tokenOut, amount);
        else (quoted, updatedAt) = venue.quoteExactInput(pool, tokenIn, tokenOut, amount);
        if (quoted == 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_QUOTE_AGE)
        {
            revert InvalidQuote();
        }
    }

    function _minimum(uint256 quoted, uint256 slippage) internal pure returns (uint256) {
        return Math.max(1, Math.mulDiv(quoted, BPS - slippage, BPS));
    }

    /// @dev Callers hold the reentrancy lock. Measure transfers instead of trusting return data.
    function _swapInput(bytes32 pool, address tokenIn, address tokenOut, uint256 amount, uint256 minimum)
        internal
        returns (uint256 received)
    {
        if (amount == 0 || minimum == 0 || tokenIn == tokenOut) revert ZeroAmount();
        uint256 beforeIn = _balance(tokenIn);
        uint256 beforeOut = _balance(tokenOut);
        if (tokenIn != address(0)) IERC20(tokenIn).forceApprove(address(venue), amount);
        venue.swapExactInput{value: tokenIn == address(0) ? amount : 0}(
            pool, tokenIn, tokenOut, amount, minimum, address(this)
        );
        if (tokenIn != address(0)) IERC20(tokenIn).forceApprove(address(venue), 0);
        uint256 afterIn = _balance(tokenIn);
        uint256 afterOut = _balance(tokenOut);
        if (afterIn > beforeIn || beforeIn - afterIn != amount || afterOut < beforeOut) revert SwapAccounting();
        received = afterOut - beforeOut;
        if (received < minimum) revert SwapAccounting();
    }

    function _swapOutput(bytes32 pool, address tokenIn, address tokenOut, uint256 amount, uint256 maximum)
        internal
        returns (uint256 spent)
    {
        uint256 beforeIn = _balance(tokenIn);
        uint256 beforeOut = _balance(tokenOut);
        if (tokenIn != address(0)) IERC20(tokenIn).forceApprove(address(venue), maximum);
        venue.swapExactOutput{value: tokenIn == address(0) ? maximum : 0}(
            pool, tokenIn, tokenOut, amount, maximum, address(this)
        );
        if (tokenIn != address(0)) IERC20(tokenIn).forceApprove(address(venue), 0);
        uint256 afterIn = _balance(tokenIn);
        uint256 afterOut = _balance(tokenOut);
        if (afterIn >= beforeIn || afterOut < beforeOut || afterOut - beforeOut != amount) revert SwapAccounting();
        spent = beforeIn - afterIn;
        if (spent > maximum) revert SwapAccounting();
    }

    function _quotedSwap(bytes32 pool, address tokenIn, address tokenOut, uint256 amount, uint256 slippage)
        internal
        returns (uint256)
    {
        return _swapInput(
            pool, tokenIn, tokenOut, amount, _minimum(_quote(pool, tokenIn, tokenOut, amount, false), slippage)
        );
    }

    function _send(address asset, address recipient, uint256 amount) internal {
        if (asset == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(asset).safeTransfer(recipient, amount);
        }
    }
}
