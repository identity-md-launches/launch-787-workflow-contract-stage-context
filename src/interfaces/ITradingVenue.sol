// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Required immutable swap/oracle adapter interface. Native ETH is address(0).
/// @dev Quotes MUST come from a manipulation-resistant, independently reviewed price source,
/// including fees/price impact, with the actual observation timestamp (not the query time).
/// A fresh zero-output quote means sub-unit rounding. Missing/unusable pricing MUST revert
/// or carry an invalid timestamp, since staking may retire a fresh zero-output batch as dust.
/// No caller-selected routes, callbacks, approvals, arbitrary calldata or recipients are exposed
/// by the application contracts. The adapter must validate poolId against both currencies.
interface ITradingVenue {
    function quoteExactInput(bytes32 poolId, address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 updatedAt);

    function quoteExactOutput(bytes32 poolId, address tokenIn, address tokenOut, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint256 updatedAt);

    /// @dev Pull precisely amountIn (or require msg.value == amountIn); send output to recipient.
    function swapExactInput(
        bytes32 poolId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external payable;

    /// @dev Pull at most maxIn; deliver exactly amountOut. For native input, refund all unused
    /// msg.value to msg.sender before returning. Never retain an approval or a refund credit.
    function swapExactOutput(
        bytes32 poolId,
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxIn,
        address recipient
    ) external payable;
}
