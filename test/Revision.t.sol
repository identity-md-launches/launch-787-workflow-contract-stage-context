// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, SniperVault, CompanyStaking, Trading, MockERC20} from "./Base.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITradingVenue} from "../src/interfaces/ITradingVenue.sol";

contract DeferredRewardsTest is BaseTest {
    function _staleSale(bool emergency) private returns (uint256 share) {
        SniperVault.Position memory p = _buy(address(nativeTarget));
        vm.prank(OWNER);
        vault.setSlippageBps(1000);
        vm.warp(START + 16 minutes);
        _price(5);
        uint256 beforeEth = address(vault).balance;
        if (emergency) {
            vm.prank(OWNER);
            vault.pause();
            vm.prank(OWNER);
            vault.emergencySell(address(nativeTarget));
        } else {
            vm.prank(KEEPER);
            vault.sell(address(nativeTarget));
        }
        uint256 proceeds = emergency ? p.entryCost * 5 : p.entryCost;
        uint256 cost = emergency ? p.entryCost : p.entryCost / 5;
        share = (proceeds - cost) * 3000 / 10_000;
        assertEq(address(vault).balance, beforeEth + proceeds);
        assertEq(vault.pendingRewardsEth(address(nativeTarget)), share);
        assertEq(vault.totalPendingRewardsEth(), share);
        assertEq(vault.availableBalance(address(0)), beforeEth + proceeds - share);
        assertEq(staking.rewardLiability(), 0);
        assertEq(vault.positionOf(address(nativeTarget)).nextLevel, emergency ? 5 : 1);
        assertEq(vault.positionOf(address(nativeTarget)).remainingAmount, emergency ? 0 : p.originalAmount * 4 / 5);
    }

    function test_staleConversionDoesNotBlockLadderAndFundsLaterDay() public {
        uint256 share = _staleSale(false);
        vm.warp(START + 1 days);
        _refreshRates();
        uint256 beforeEth = address(vault).balance;
        vm.prank(EVE);
        assertEq(vault.fundPendingRewards(address(nativeTarget)), share * 1000);
        assertEq(address(vault).balance, beforeEth - share);
        assertEq(vault.totalPendingRewardsEth(), 0);
        assertEq(vault.pendingRewardsEth(address(nativeTarget)), 0);
        assertEq(vault.positionOf(address(nativeTarget)).rewardsImd, share * 1000);
        assertEq(staking.rewardLiability(), share * 1000);
        (uint256 funded,,) = staking.batches(BATCH + 1);
        assertEq(funded, share * 1000);
        (funded,,) = staking.batches(BATCH);
        assertEq(funded, 0);
        assertEq(imd.balanceOf(EVE), 0);
        assertEq(imd.allowance(address(vault), address(staking)), 0);
        vm.expectRevert(Trading.ZeroAmount.selector);
        vault.fundPendingRewards(address(nativeTarget));
    }

    function test_staleConversionDoesNotBlockEmergencyWhilePaused() public {
        _staleSale(true);
        _refreshRates();
        vault.fundPendingRewards(address(nativeTarget));
        assertEq(vault.totalPendingRewardsEth(), 0);
    }

    function test_dustConversionKeepsProceedsAndAccumulatesShares() public {
        vm.startPrank(OWNER);
        vault.withdraw(address(0), address(vault).balance - 1000);
        vault.setMaxSpendBps(10_000);
        vm.stopPrank();
        assertEq(_buy(address(nativeTarget)).entryCost, 1000);
        venue.setRate(IMD_POOL, address(0), address(imd), 1, 1e9);
        _price(5);
        vm.prank(KEEPER);
        vault.sell(address(nativeTarget));
        assertEq(address(vault).balance, 1000);
        assertEq(vault.pendingRewardsEth(address(nativeTarget)), 240);
        vm.expectRevert(Trading.InvalidQuote.selector);
        vault.fundPendingRewards(address(nativeTarget));
        venue.setRate(IMD_POOL, address(0), address(imd), 1, 1000);
        _price(10);
        vm.prank(KEEPER);
        vault.sell(address(nativeTarget));
        assertEq(vault.pendingRewardsEth(address(nativeTarget)), 780);
        _price(25);
        vm.prank(KEEPER);
        vault.sell(address(nativeTarget));
        // This sale's 1440 wei share is independently convertible; prior dust stays reserved.
        assertEq(staking.rewardLiability(), 1);
        assertEq(vault.pendingRewardsEth(address(nativeTarget)), 780);
        venue.setRate(IMD_POOL, address(0), address(imd), 1, 100);
        assertEq(vault.fundPendingRewards(address(nativeTarget)), 7);
        assertEq(staking.rewardLiability(), 8);
        assertEq(vault.totalPendingRewardsEth(), 0);
    }

    function testFuzz_invalidConversionTimestampsDefer(uint8 kind) public {
        _buy(address(nativeTarget));
        _price(5);
        uint256 invalidTime = kind % 3 == 0 ? 0 : (kind % 3 == 1 ? START + 1 : START - 901);
        venue.setTimestamp(IMD_POOL, address(0), address(imd), invalidTime);
        vm.prank(KEEPER);
        vault.sell(address(nativeTarget));
        assertEq(vault.positionOf(address(nativeTarget)).nextLevel, 1);
        assertGt(vault.pendingRewardsEth(address(nativeTarget)), 0);
    }

    function test_revertingConversionQuoteDefers() public {
        _buy(address(nativeTarget));
        _price(5);
        vm.mockCallRevert(
            address(venue),
            abi.encodeWithSelector(ITradingVenue.quoteExactInput.selector, IMD_POOL, address(0), address(imd)),
            abi.encodeWithSignature("Error(string)", "quote unavailable")
        );
        vm.prank(OWNER);
        vault.emergencySell(address(nativeTarget));
        assertEq(vault.positionOf(address(nativeTarget)).remainingAmount, 0);
        assertGt(vault.totalPendingRewardsEth(), 0);
    }

    function test_failedRetryPreservesReserveAndApprovals() public {
        uint256 share = _staleSale(false);
        uint256 beforeEth = address(vault).balance;
        vm.expectRevert(Trading.InvalidQuote.selector);
        vault.fundPendingRewards(address(nativeTarget));
        _refreshRates();
        venue.configure(10_000, false, IMD_POOL);
        vm.expectRevert("swap failed");
        vault.fundPendingRewards(address(nativeTarget));
        venue.configure(10_000, false, bytes32(0));
        imd.setBlockedRecipient(address(staking));
        vm.expectRevert("recipient blocked");
        vault.fundPendingRewards(address(nativeTarget));
        assertEq(address(vault).balance, beforeEth);
        assertEq(vault.totalPendingRewardsEth(), share);
        assertEq(vault.pendingRewardsEth(address(nativeTarget)), share);
        assertEq(staking.totalRewardsFunded(), 0);
        assertEq(imd.allowance(address(vault), address(staking)), 0);
        imd.setBlockedRecipient(address(0));
        vault.fundPendingRewards(address(nativeTarget));
        assertEq(vault.totalPendingRewardsEth(), 0);
    }

    function test_ownerCannotWithdrawBookedShareOrCancelItWithSettings() public {
        uint256 share = _staleSale(false);
        vm.startPrank(OWNER);
        vault.setStakerShareBps(0);
        vault.pause();
        vm.expectRevert(SniperVault.ReservedRewards.selector);
        vault.withdraw(address(0), address(vault).balance);
        vault.withdrawAll();
        vm.stopPrank();
        assertEq(address(vault).balance, share);
        assertEq(vault.availableBalance(address(0)), 0);
        assertEq(vault.positionOf(address(nativeTarget)).remainingAmount, 0);
        _refreshRates();
        assertEq(vault.fundPendingRewards(address(nativeTarget)), share * 1000);
        assertEq(address(vault).balance, 0);
        assertEq(staking.rewardLiability(), share * 1000);
    }

    function test_keeperBudgetExcludesPendingRewards() public {
        uint256 share = _staleSale(false);
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        other.mint(address(venue), 1e27);
        registry.setLaunch(address(other), FACTORY, address(0), NATIVE_POOL);
        venue.setRate(NATIVE_POOL, address(0), address(other), 100, 1);
        uint256 budget = vault.availableBalance(address(0));
        vm.startPrank(OWNER);
        vault.setMaxSpendBps(10_000);
        vault.setSlippageBps(0);
        vm.stopPrank();
        vm.prank(KEEPER);
        vault.snipe(address(other));
        assertEq(vault.positionOf(address(other)).entryCost, budget);
        assertEq(address(vault).balance, share);
        assertEq(vault.totalPendingRewardsEth(), share);
    }

    function test_retryReentrancyCannotSpendReserveTwice() public {
        uint256 share = _staleSale(false);
        _refreshRates();
        venue.setCallback(address(vault), abi.encodeCall(vault.fundPendingRewards, (address(nativeTarget))));
        vault.fundPendingRewards(address(nativeTarget));
        assertFalse(venue.callbackSucceeded());
        assertEq(venue.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(staking.rewardLiability(), share * 1000);
        assertEq(vault.totalPendingRewardsEth(), 0);
    }

    function test_reservesForDifferentPositionsSettleIndependently() public {
        uint256 firstShare = _staleSale(false);
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        other.mint(address(venue), 1e27);
        registry.setLaunch(address(other), FACTORY, address(0), NATIVE_POOL);
        venue.setRate(NATIVE_POOL, address(0), address(other), 10_000, 1);
        SniperVault.Position memory p = _buy(address(other));
        venue.setRate(NATIVE_POOL, address(other), address(0), 5, 10_000);
        vm.prank(OWNER);
        vault.emergencySell(address(other));
        uint256 secondShare = (p.entryCost * 4) * 3000 / 10_000;
        assertEq(vault.totalPendingRewardsEth(), firstShare + secondShare);
        assertEq(vault.pendingRewardsEth(address(other)), secondShare);
        _refreshRates();
        vault.fundPendingRewards(address(other));
        assertEq(vault.totalPendingRewardsEth(), firstShare);
        assertEq(vault.pendingRewardsEth(address(nativeTarget)), firstShare);
        assertEq(vault.positionOf(address(other)).rewardsImd, secondShare * 1000);
        vault.fundPendingRewards(address(nativeTarget));
        assertEq(vault.totalPendingRewardsEth(), 0);
        assertEq(staking.totalRewardsFunded(), (firstShare + secondShare) * 1000);
    }

    function test_failedPositionSaleDoesNotBookRewards() public {
        _buy(address(nativeTarget));
        vm.warp(START + 16 minutes);
        _price(5);
        venue.configure(10_000, false, NATIVE_POOL);
        vm.prank(KEEPER);
        vm.expectRevert("swap failed");
        vault.sell(address(nativeTarget));
        assertEq(vault.totalPendingRewardsEth(), 0);
        assertEq(vault.positionOf(address(nativeTarget)).nextLevel, 0);
    }
}

contract BurnRevisionTest is BaseTest {
    function _dustRemainder(bool ethPaired) private {
        if (ethPaired) registry.setLaunch(address(company), FACTORY, address(0), COMPANY_POOL);
        _stake(ALICE, 1 ether);
        _stake(BOB, 2 ether);
        staking.notifyReward(10);
        vm.warp(START + 1 days);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 3);
        vm.prank(BOB);
        assertEq(staking.claimAll(), 6);
        vm.warp(START + 8 days);
        _refreshRates();
        if (!ethPaired) venue.setRate(COMPANY_POOL, address(imd), address(company), 1, 10);
        assertEq(staking.burnExpired(BATCH), 0);
        (,, bool burned) = staking.batches(BATCH);
        assertTrue(burned);
        assertEq(staking.rewardLiability(), 0);
        assertEq(staking.totalImdDust(), 1);
        assertEq(staking.totalImdBurned(), 0);
        assertEq(imd.balanceOf(address(staking)), 1);
        assertEq(company.balanceOf(address(staking)), 3 ether);
        assertEq(company.balanceOf(staking.DEAD()), 0);
        assertEq(staking.totalRewardsFunded(), staking.totalRewardsPaid() + staking.totalImdDust());
        vm.warp(START + 400 days);
        vm.expectRevert(CompanyStaking.BatchAlreadyBurned.selector);
        staking.burnExpired(BATCH);
    }

    function test_dustEthPairClosesWithoutSwap() public {
        _dustRemainder(true);
    }

    function test_dustImdPairClosesWithoutSwap() public {
        _dustRemainder(false);
    }

    function test_zeroSecondHopClosesBeforeSpendingAnyImd() public {
        registry.setLaunch(address(company), FACTORY, address(0), COMPANY_POOL);
        staking.notifyReward(1000);
        vm.warp(START + 8 days);
        _refreshRates();
        venue.setRate(COMPANY_POOL, address(0), address(company), 1, 10);
        assertEq(staking.burnExpired(BATCH), 0);
        assertEq(staking.totalImdDust(), 1000);
        assertEq(imd.balanceOf(address(staking)), 1000);
        assertEq(address(staking).balance, 0);
        assertEq(imd.allowance(address(staking), address(venue)), 0);
    }

    function test_staleZeroQuoteCannotRetireLiability() public {
        staking.notifyReward(1);
        venue.setRate(COMPANY_POOL, address(imd), address(company), 1, 10);
        vm.warp(START + 8 days);
        vm.expectRevert(Trading.InvalidQuote.selector);
        staking.burnExpired(BATCH);
        assertEq(staking.totalImdDust(), 0);
        assertEq(staking.rewardLiability(), 1);
        (,, bool burned) = staking.batches(BATCH);
        assertFalse(burned);
    }

    function test_dustRetirementPreservesOtherBatchAndDonations() public {
        staking.notifyReward(1);
        vm.warp(START + 8 days);
        staking.notifyReward(10 ether);
        imd.transfer(address(staking), 9);
        _refreshRates();
        venue.setRate(COMPANY_POOL, address(imd), address(company), 1, 10);
        staking.burnExpired(BATCH);
        assertEq(staking.rewardLiability(), 10 ether);
        assertEq(staking.totalImdDust(), 1);
        assertEq(imd.balanceOf(address(staking)), 10 ether + 10);
        vm.warp(START + 16 days);
        _refreshRates();
        staking.burnExpired(BATCH + 8);
        assertEq(imd.balanceOf(address(staking)), 10);
        assertEq(staking.totalImdDust(), 1);
        assertEq(staking.totalRewardsFunded(), staking.totalImdBurned() + staking.totalImdDust());
    }

    function test_twoHopNineteenPercentShortfallRevertsAtomically() public {
        registry.setLaunch(address(company), FACTORY, address(0), COMPANY_POOL);
        staking.notifyReward(1000 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        venue.configure(9000, false, bytes32(0));
        vm.expectRevert("slippage");
        staking.burnExpired(BATCH);
        assertEq(company.balanceOf(staking.DEAD()), 0);
        assertEq(staking.rewardLiability(), 1000 ether);
        assertEq(imd.balanceOf(address(staking)), 1000 ether);
        assertEq(address(staking).balance, 0);
        assertEq(staking.totalImdBurned(), 0);
        assertEq(staking.totalImdDust(), 0);
        (,, bool burned) = staking.batches(BATCH);
        assertFalse(burned);
        venue.configure(9500, false, bytes32(0));
        assertEq(staking.burnExpired(BATCH), 1805 ether);
    }

    function test_singleHopTenPercentBoundaryStillSucceeds() public {
        staking.notifyReward(1000 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        venue.configure(9000, false, bytes32(0));
        assertEq(staking.burnExpired(BATCH), 1800 ether);
    }

    function testFuzz_endToEndBurnBound(uint256 execution) public {
        execution = bound(execution, 9000, 10_000);
        registry.setLaunch(address(company), FACTORY, address(0), COMPANY_POOL);
        staking.notifyReward(1000 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        venue.configure(execution, false, bytes32(0));
        uint256 expected = (1 ether * execution / 10_000) * 2000 * execution / 10_000;
        if (expected < 1800 ether) {
            vm.expectRevert("slippage");
            staking.burnExpired(BATCH);
            assertEq(staking.rewardLiability(), 1000 ether);
        } else {
            assertEq(staking.burnExpired(BATCH), expected);
            assertGe(company.balanceOf(staking.DEAD()), 1800 ether);
        }
    }
}
