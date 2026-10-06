// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract LaunchTokenSequenceHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors = [address(0xA01), address(0xA02), address(0xA03), address(0xA04)];
    uint256[4] public balances;
    mapping(uint256 => mapping(uint256 => uint256)) public allowances;

    constructor(LaunchToken token_) {
        token = token_;
        balances[0] = 1e27;
    }

    function transfer(uint256 from, uint256 to, uint256 amount) public {
        from %= 4;
        to %= 4;
        amount = bound(amount, 0, 1e27 + 1);
        vm.prank(actors[from]);
        if (amount > balances[from]) {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "ERC20InsufficientBalance(address,uint256,uint256)", actors[from], balances[from], amount
                )
            );
            token.transfer(actors[to], amount);
        } else {
            assertTrue(token.transfer(actors[to], amount));
            balances[from] -= amount;
            balances[to] += amount;
        }
    }

    function approve(uint256 owner, uint256 spender, uint256 amount) public {
        owner %= 4;
        spender %= 4;
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(uint256 spender, uint256 from, uint256 to, uint256 amount) public {
        spender %= 4;
        from %= 4;
        to %= 4;
        amount = bound(amount, 0, 1e27 + 1);
        uint256 allowed = allowances[from][spender];
        vm.prank(actors[spender]);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "ERC20InsufficientAllowance(address,uint256,uint256)", actors[spender], allowed, amount
                )
            );
            token.transferFrom(actors[from], actors[to], amount);
        } else if (amount > balances[from]) {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "ERC20InsufficientBalance(address,uint256,uint256)", actors[from], balances[from], amount
                )
            );
            token.transferFrom(actors[from], actors[to], amount);
        } else {
            assertTrue(token.transferFrom(actors[from], actors[to], amount));
            if (allowed != type(uint256).max) allowances[from][spender] -= amount;
            balances[from] -= amount;
            balances[to] += amount;
        }
    }

    function assertAccounting() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(actors[i]), balances[i], "exact transfer amounts");
            sum += token.balanceOf(actors[i]);
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), allowances[i][j]);
            }
        }
        assertEq(sum, 1e27, "all balances conserve launch supply");
        assertEq(token.totalSupply(), 1e27, "fixed supply");
        assertEq(token.balanceOf(address(0)), 0);
    }
}

contract LaunchTokenInvariantTest is Test {
    LaunchTokenSequenceHandler private handler;

    function setUp() public {
        LaunchToken token = new LaunchToken();
        handler = new LaunchTokenSequenceHandler(token);
        token.transfer(handler.actors(0), token.totalSupply());
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyBalancesAndAllowances() public view {
        handler.assertAccounting();
    }

    function test_zeroFullSupplySelfTransferAndInfiniteAllowance() public {
        handler.transfer(0, 0, 1e27);
        handler.transfer(1, 2, 0);
        handler.approve(0, 1, type(uint256).max);
        handler.transferFrom(1, 0, 2, 1e27);
        handler.transferFrom(1, 0, 2, 1); // Insufficient balance, despite infinite allowance.
        handler.approve(2, 1, 1e27);
        handler.transferFrom(1, 2, 0, 1e27);
        handler.transferFrom(1, 2, 0, 1); // Allowance was consumed exactly.
        handler.assertAccounting();
    }
}
