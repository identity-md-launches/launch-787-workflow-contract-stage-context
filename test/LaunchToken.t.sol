// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_launchSupplyAndMetadata() public view {
        assertEq(token.name(), "Zero Person Billion Dollar Company");
        assertEq(token.symbol(), "COMPANY");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        token.transfer(address(0xCAFE), amount);
        assertEq(token.balanceOf(address(0xCAFE)), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceTransferAndRevocation() public {
        token.approve(address(0xB0B), 42 ether);
        vm.prank(address(0xB0B));
        token.transferFrom(address(this), address(0xCAFE), 12 ether);
        assertEq(token.allowance(address(this), address(0xB0B)), 30 ether);
        token.approve(address(0xB0B), 0);
        vm.prank(address(0xB0B));
        vm.expectRevert();
        token.transferFrom(address(this), address(0xCAFE), 1);
    }

    function test_invalidTransfersRevert() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(address(0xCAFE));
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noAdministrativeMintOrUpgrade() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", address(this), 1),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("initialize(address)", address(this)),
            abi.encodeWithSignature("setFee(uint256)", 100)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
