// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, SniperVault, Trading} from "./Base.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CallbackOwner {
    SniperVault public vault;
    bool public reject;
    bool public reenter;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function configure(SniperVault vault_, bool reject_, bool reenter_) external {
        vault = vault_;
        reject = reject_;
        reenter = reenter_;
    }

    function deposit() external payable {
        vault.depositETH{value: msg.value}();
    }

    function withdraw() external {
        vault.withdrawAll();
    }

    receive() external payable {
        require(!reject, "owner rejects ETH");
        if (reenter) {
            (callbackSucceeded, callbackResult) = address(vault).call(abi.encodeCall(vault.withdrawAll, ()));
        }
    }
}

contract WithdrawalSafetyTest is BaseTest {
    function test_reentrantOwnerCannotWithdrawAgain() public {
        CallbackOwner receiver = new CallbackOwner();
        SniperVault other = new SniperVault(address(receiver), address(staking));
        receiver.configure(other, false, true);
        vm.deal(address(this), 1 ether);
        receiver.deposit{value: 1 ether}();
        receiver.withdraw();
        assertFalse(receiver.callbackSucceeded());
        assertEq(
            receiver.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(receiver).balance, 1 ether);
        assertEq(address(other).balance, 0);
    }

    function test_rejectedNativeWithdrawalLeavesFundsRetryable() public {
        CallbackOwner receiver = new CallbackOwner();
        SniperVault other = new SniperVault(address(receiver), address(staking));
        receiver.configure(other, true, false);
        vm.deal(address(this), 1 ether);
        receiver.deposit{value: 1 ether}();
        vm.expectRevert(Trading.NativeTransferFailed.selector);
        receiver.withdraw();
        assertEq(address(other).balance, 1 ether);
        receiver.configure(other, false, false);
        receiver.withdraw();
        assertEq(address(receiver).balance, 1 ether);
    }

    function test_failedTokenWithdrawalDoesNotRetirePosition() public {
        SniperVault.Position memory p = _buy(address(target));
        target.configure(0, true);
        vm.prank(OWNER);
        vm.expectRevert("token transfer failed");
        vault.withdraw(address(target), p.originalAmount);
        assertEq(vault.positionOf(address(target)).remainingAmount, p.originalAmount);
        assertEq(vault.positionOf(address(target)).remainingCost, p.entryCost);
        target.configure(0, false);
        vm.prank(OWNER);
        vault.withdraw(address(target), p.originalAmount);
        assertEq(target.balanceOf(OWNER), p.originalAmount);
    }

    function test_unexpectedNativeSenderRejectedAndEmptyVaultCannotSnipe() public {
        vm.deal(EVE, 1 ether);
        vm.prank(EVE);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(EVE);
        (ok,) = address(staking).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(OWNER);
        vault.withdrawAll();
        vm.prank(KEEPER);
        vm.expectRevert(Trading.ZeroAmount.selector);
        vault.snipe(address(target));
    }
}
