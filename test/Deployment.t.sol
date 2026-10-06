// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {CompanyStaking} from "../src/CompanyStaking.sol";
import {SniperVault} from "../src/SniperVault.sol";
import {Trading} from "../src/lib/Trading.sol";

contract LocalFactoryProbe {
    function deploy(bytes memory creationCode, bytes32 salt) external payable returns (address result) {
        assembly ("memory-safe") {
            result := create2(callvalue(), add(creationCode, 32), mload(creationCode), salt)
        }
    }
}

contract DeploymentTest is Test {
    function test_factoryOrderPreservesSupplyAndExplicitOwnershipWithoutInitialization() public {
        LocalFactoryProbe factory = new LocalFactoryProbe();
        address token = factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1)));
        address staking = factory.deploy(
            abi.encodePacked(
                type(CompanyStaking).creationCode,
                abi.encode(token, address(1), address(2), address(3), address(4), bytes32(uint256(5)), block.chainid)
            ),
            bytes32(uint256(2))
        );
        address owner = address(0xBEEF);
        address vault = factory.deploy(
            abi.encodePacked(type(SniperVault).creationCode, abi.encode(owner, staking)), bytes32(uint256(3))
        );
        assertEq(LaunchToken(token).totalSupply(), 1e27);
        assertEq(LaunchToken(token).balanceOf(address(factory)), 1e27);
        assertEq(SniperVault(payable(vault)).owner(), owner);
        assertEq(SniperVault(payable(vault)).imd(), address(1));
        assertEq(address(SniperVault(payable(vault)).staking()), staking);
        assertEq(CompanyStaking(payable(staking)).company(), token);
        _checkRuntime(token);
        _checkRuntime(staking);
        _checkRuntime(vault);
    }

    function test_nonpayableConstructorsRejectValue() public {
        LocalFactoryProbe factory = new LocalFactoryProbe();
        vm.deal(address(this), 3);
        address token = factory.deploy{value: 1}(type(LaunchToken).creationCode, bytes32(uint256(1)));
        assertEq(token, address(0));
        address staking = factory.deploy{value: 1}(
            abi.encodePacked(
                type(CompanyStaking).creationCode,
                abi.encode(
                    address(9), address(1), address(2), address(3), address(4), bytes32(uint256(5)), block.chainid
                )
            ),
            bytes32(uint256(2))
        );
        assertEq(staking, address(0));
        CompanyStaking valid = new CompanyStaking(
            address(9), address(1), address(2), address(3), address(4), bytes32(uint256(5)), block.chainid
        );
        address vault = factory.deploy{value: 1}(
            abi.encodePacked(type(SniperVault).creationCode, abi.encode(address(1), address(valid))),
            bytes32(uint256(3))
        );
        assertEq(vault, address(0));
    }

    function test_invalidConstructorParameters() public {
        vm.expectRevert(Trading.InvalidConfiguration.selector);
        new CompanyStaking(
            address(1), address(1), address(2), address(3), address(4), bytes32(uint256(5)), block.chainid
        );
        vm.expectRevert(Trading.InvalidConfiguration.selector);
        new CompanyStaking(
            address(0), address(1), address(2), address(3), address(4), bytes32(uint256(5)), block.chainid
        );
        vm.expectRevert(Trading.InvalidConfiguration.selector);
        new CompanyStaking(
            address(9), address(0), address(2), address(3), address(4), bytes32(uint256(5)), block.chainid
        );
        vm.expectRevert(Trading.InvalidConfiguration.selector);
        new CompanyStaking(
            address(9), address(1), address(0), address(3), address(4), bytes32(uint256(5)), block.chainid
        );
        vm.expectRevert(Trading.InvalidConfiguration.selector);
        new CompanyStaking(
            address(9), address(1), address(2), address(0), address(4), bytes32(uint256(5)), block.chainid
        );
        vm.expectRevert(Trading.InvalidConfiguration.selector);
        new CompanyStaking(
            address(9), address(1), address(2), address(3), address(0), bytes32(uint256(5)), block.chainid
        );
        vm.expectRevert(Trading.InvalidConfiguration.selector);
        new CompanyStaking(address(9), address(1), address(2), address(3), address(4), bytes32(0), block.chainid);
        vm.expectRevert(Trading.WrongChain.selector);
        new CompanyStaking(
            address(9), address(1), address(2), address(3), address(4), bytes32(uint256(5)), block.chainid + 1
        );
        CompanyStaking staking = new CompanyStaking(
            address(9), address(1), address(2), address(3), address(4), bytes32(uint256(5)), block.chainid
        );
        vm.expectRevert(Trading.InvalidConfiguration.selector);
        new SniperVault(address(0), address(staking));
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
