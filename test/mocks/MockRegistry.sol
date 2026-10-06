// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILaunchRegistry} from "../../src/interfaces/ILaunchRegistry.sol";

contract MockRegistry is ILaunchRegistry {
    struct Launch {
        address factory;
        address asset;
        bytes32 pool;
    }

    mapping(address => Launch) private launches;

    function setLaunch(address token, address factory, address asset, bytes32 pool) external {
        launches[token] = Launch(factory, asset, pool);
    }

    function getLaunch(address token) external view returns (address factory, address asset, bytes32 pool) {
        Launch storage launch = launches[token];
        return (launch.factory, launch.asset, launch.pool);
    }
}
