// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Required network integration interface, not an asserted native ProjectFactory ABI.
/// @dev An immutable, independently verified registry adapter must prove origin from the
/// canonical factory, and identify the launch's exact pool (including currencies, fee and hook).
interface ILaunchRegistry {
    function getLaunch(address token) external view returns (address factory, address pairedAsset, bytes32 poolId);
}
