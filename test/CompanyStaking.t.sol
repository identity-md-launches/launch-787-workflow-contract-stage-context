// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, CompanyStaking, SniperVault, Trading, MockERC20} from "./Base.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CompanyStakingTest is BaseTest {
    function test_dailyWeightsIncludeUnstakedTimeAndLateEntryOnlyForItsDuration() public {
        _stake(ALICE, 100 ether);
        vm.warp(START + 12 hours);
        _stake(BOB, 100 ether);
        staking.notifyReward(300 ether);
        vm.warp(START + 18 hours);
        vm.prank(ALICE);
        staking.unstake(100 ether);
        assertEq(staking.totalStaked(), 100 ether);
        assertEq(staking.balanceOf(ALICE), 0);
        vm.warp(START + 1 days);
        (uint256 personal, uint256 aggregate) = staking.stakeSeconds(ALICE, BATCH);
        assertEq(personal, 100 ether * 18 hours);
        assertEq(aggregate, 100 ether * 30 hours);
        assertEq(staking.claimable(ALICE, BATCH), 180 ether);
        assertEq(staking.claimable(BOB, BATCH), 120 ether);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 180 ether);
        vm.prank(BOB);
        assertEq(staking.claimAll(), 120 ether);
        assertEq(staking.rewardLiability(), 0);
        assertEq(staking.totalRewardsPaid(), 300 ether);
        assertEq(company.balanceOf(address(staking)), staking.totalStaked());
    }

    function testFuzz_weightedRewardConservation(uint256 a, uint256 b, uint256 join, uint256 reward) public {
        a = bound(a, 1, 100_000 ether);
        b = bound(b, 1, 100_000 ether);
        join = bound(join, 0, 1 days - 1);
        reward = bound(reward, 1, 1_000_000 ether);
        _stake(ALICE, a);
        vm.warp(START + join);
        _stake(BOB, b);
        staking.notifyReward(reward);
        vm.warp(START + 1 days);
        uint256 weightA = a * 1 days;
        uint256 weightB = b * (1 days - join);
        uint256 expectedA = reward * weightA / (weightA + weightB);
        uint256 expectedB = reward * weightB / (weightA + weightB);
        vm.prank(BOB);
        assertEq(staking.claimAll(), expectedB);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), expectedA);
        uint256 dust = reward - expectedA - expectedB;
        assertLe(dust, 1);
        assertEq(imd.balanceOf(address(staking)), dust);
        assertEq(staking.rewardLiability(), dust);
        vm.warp(START + 8 days);
        _refreshRates();
        staking.burnExpired(BATCH);
        assertEq(staking.rewardLiability(), 0);
        assertEq(company.balanceOf(staking.DEAD()), dust * 2);
        assertEq(company.balanceOf(address(staking)), a + b);
        assertEq(staking.totalRewardsPaid() + staking.totalImdBurned(), reward);
    }

    function test_sameTimestampStakeUnstakeHasZeroWeight() public {
        _stake(ALICE, 100 ether);
        vm.prank(ALICE);
        staking.unstake(100 ether);
        _stake(BOB, 10 ether);
        staking.notifyReward(10 ether);
        vm.warp(START + 1 days);
        assertEq(staking.claimable(ALICE, BATCH), 0);
        assertEq(staking.claimable(BOB, BATCH), 10 ether);
        (uint256 personal, uint256 total) = staking.stakeSeconds(ALICE, BATCH);
        assertEq(personal, 0);
        assertEq(total, 10 ether * 1 days);
    }

    function test_repeatedSameTimestampChangesPreserveEarlierIntegral() public {
        _stake(ALICE, 10 ether);
        vm.warp(START + 12 hours);
        _stake(ALICE, 10 ether);
        vm.prank(ALICE);
        staking.unstake(5 ether);
        _stake(ALICE, 5 ether);
        vm.warp(START + 1 days);
        (uint256 personal, uint256 aggregate) = staking.stakeSeconds(ALICE, BATCH);
        assertEq(personal, 30 ether * 12 hours);
        assertEq(aggregate, personal);
    }

    function test_stakingOnClosingBoundaryDoesNotShareYesterday() public {
        _stake(ALICE, 10 ether);
        staking.notifyReward(25 ether);
        vm.warp(START + 1 days);
        _stake(BOB, 1000 ether);
        assertEq(staking.claimable(BOB, BATCH), 0);
        assertEq(staking.claimable(ALICE, BATCH), 25 ether);
        assertEq(staking.claimable(ALICE, BATCH + 1), 0);
    }

    function test_claimAllIncludesSevenDaysAndSkipsExpiredAndCurrent() public {
        _stake(ALICE, 10 ether);
        for (uint256 i; i < 10; ++i) {
            vm.warp(START + i * 1 days);
            staking.notifyReward(10 ether);
        }
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 70 ether);
        assertFalse(staking.claimed(BATCH + 1, ALICE));
        assertTrue(staking.claimed(BATCH + 2, ALICE));
        assertFalse(staking.claimed(BATCH + 9, ALICE));
        assertEq(staking.rewardLiability(), 30 ether);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 0);
        vm.warp(START + 10 days);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 10 ether);
    }

    function test_expiryBoundaryHasNoOverlapOrGap() public {
        _stake(ALICE, 1 ether);
        _stake(BOB, 1 ether);
        staking.notifyReward(100 ether);
        vm.warp(START + 8 days - 1);
        vm.expectRevert(CompanyStaking.BatchNotExpired.selector);
        staking.burnExpired(BATCH);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 50 ether);
        vm.warp(START + 8 days);
        assertEq(staking.claimable(BOB, BATCH), 0);
        vm.prank(BOB);
        vm.expectRevert(CompanyStaking.BatchNotClaimable.selector);
        staking.claim(BATCH);
        _refreshRates();
        vm.prank(EVE);
        assertEq(staking.burnExpired(BATCH), 100 ether);
        assertEq(company.balanceOf(staking.DEAD()), 100 ether);
        assertEq(staking.rewardLiability(), 0);
        assertEq(staking.totalImdBurned(), 50 ether);
        assertEq(imd.balanceOf(EVE), 0);
        assertEq(company.balanceOf(EVE), 0);
    }

    function test_zeroStakersRewardAndRoundingDustCanBeBurned() public {
        staking.notifyReward(11 ether);
        vm.warp(START + 1 days);
        _stake(ALICE, 1 ether);
        assertEq(staking.claimable(ALICE, BATCH), 0);
        vm.warp(START + 8 days);
        _refreshRates();
        staking.burnExpired(BATCH);
        assertEq(company.balanceOf(staking.DEAD()), 22 ether);
        assertEq(company.balanceOf(address(staking)), 1 ether);
        assertEq(staking.totalCompanyBurned(), 22 ether);
    }

    function test_fullyClaimedBatchCanCloseWithoutRouter() public {
        _stake(ALICE, 1 ether);
        staking.notifyReward(10 ether);
        vm.warp(START + 1 days);
        vm.prank(ALICE);
        staking.claimAll();
        vm.warp(START + 8 days);
        venue.configure(10_000, false, COMPANY_POOL);
        assertEq(staking.burnExpired(BATCH), 0);
        (,, bool burned) = staking.batches(BATCH);
        assertTrue(burned);
    }

    function test_burnCannotRepeatAndUnknownBatchFails() public {
        staking.notifyReward(10 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        staking.burnExpired(BATCH);
        vm.expectRevert(CompanyStaking.BatchAlreadyBurned.selector);
        staking.burnExpired(BATCH);
        vm.expectRevert(CompanyStaking.UnknownBatch.selector);
        staking.burnExpired(0);
        vm.expectRevert(CompanyStaking.UnknownBatch.selector);
        staking.burnExpired(type(uint256).max);
    }

    function test_burnNativePairedCompanyThroughBothPools() public {
        registry.setLaunch(address(company), FACTORY, address(0), COMPANY_POOL);
        _stake(ALICE, 100 ether);
        staking.notifyReward(100 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        vm.prank(EVE);
        staking.burnExpired(BATCH);
        assertEq(company.balanceOf(staking.DEAD()), 200 ether);
        assertEq(company.balanceOf(address(staking)), 100 ether);
        assertEq(address(staking).balance, 0);
        assertEq(imd.balanceOf(address(staking)), 0);
        assertEq(imd.allowance(address(staking), address(venue)), 0);
    }

    function test_failedSecondHopRollsBackLiabilityAndFirstHop() public {
        registry.setLaunch(address(company), FACTORY, address(0), COMPANY_POOL);
        staking.notifyReward(100 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        venue.configure(10_000, false, COMPANY_POOL);
        vm.expectRevert("swap failed");
        staking.burnExpired(BATCH);
        assertEq(staking.rewardLiability(), 100 ether);
        assertEq(imd.balanceOf(address(staking)), 100 ether);
        assertEq(address(staking).balance, 0);
        assertEq(staking.totalImdBurned(), 0);
        (,, bool burned) = staking.batches(BATCH);
        assertFalse(burned);
        venue.configure(10_000, false, bytes32(0));
        staking.burnExpired(BATCH);
        assertEq(staking.rewardLiability(), 0);
    }

    function test_burnFailureNeverSpendsPrincipalOrOtherBatches() public {
        _stake(ALICE, 100 ether);
        staking.notifyReward(10 ether);
        vm.warp(START + 8 days);
        staking.notifyReward(20 ether);
        _refreshRates();
        venue.configure(10_000, true, bytes32(0));
        vm.expectRevert(Trading.SwapAccounting.selector);
        staking.burnExpired(BATCH);
        assertEq(staking.rewardLiability(), 30 ether);
        assertEq(company.balanceOf(address(staking)), 100 ether);
        venue.configure(10_000, false, bytes32(0));
        staking.burnExpired(BATCH);
        assertEq(imd.balanceOf(address(staking)), 20 ether);
        assertEq(staking.rewardLiability(), 20 ether);
        assertEq(company.balanceOf(address(staking)), 100 ether);
        vm.prank(ALICE);
        staking.unstake(100 ether);
        assertEq(company.balanceOf(address(staking)), 0);
    }

    function test_burnRejectsInvalidCompanyOriginAndStaleQuote() public {
        staking.notifyReward(1 ether);
        vm.warp(START + 8 days);
        registry.setLaunch(address(company), EVE, address(imd), COMPANY_POOL);
        vm.expectRevert(Trading.InvalidLaunch.selector);
        staking.burnExpired(BATCH);
        registry.setLaunch(address(company), FACTORY, address(imd), COMPANY_POOL);
        vm.expectRevert(Trading.InvalidQuote.selector);
        staking.burnExpired(BATCH);
        assertEq(staking.rewardLiability(), 1 ether);
    }

    function test_reentrantBurnCannotSpendBatchTwice() public {
        staking.notifyReward(10 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        venue.setCallback(address(staking), abi.encodeCall(staking.burnExpired, (BATCH)));
        staking.burnExpired(BATCH);
        assertFalse(venue.callbackSucceeded());
        assertEq(venue.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(company.balanceOf(staking.DEAD()), 20 ether);
    }

    function test_rewardTokenCallbackCannotReenterClaim() public {
        _stake(ALICE, 10 ether);
        staking.notifyReward(10 ether);
        vm.warp(START + 1 days);
        imd.setCallback(address(staking), abi.encodeCall(staking.claimAll, ()));
        vm.prank(ALICE);
        staking.claimAll();
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(imd.balanceOf(ALICE), 10 ether);
        assertEq(staking.totalRewardsPaid(), 10 ether);
    }

    function test_failedClaimCanBeRetriedWithoutAccountingLoss() public {
        _stake(ALICE, 1 ether);
        staking.notifyReward(10 ether);
        vm.warp(START + 1 days);
        imd.configure(0, true);
        vm.prank(ALICE);
        vm.expectRevert("token transfer failed");
        staking.claimAll();
        assertFalse(staking.claimed(BATCH, ALICE));
        assertEq(staking.rewardLiability(), 10 ether);
        assertEq(staking.totalRewardsPaid(), 0);
        imd.configure(0, false);
        vm.prank(ALICE);
        assertEq(staking.claim(BATCH), 10 ether);
    }

    function test_zeroAmountsInsufficientStakeAndEarlyDuplicateClaimsFail() public {
        vm.expectRevert(Trading.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(Trading.ZeroAmount.selector);
        staking.unstake(0);
        vm.expectRevert(Trading.ZeroAmount.selector);
        staking.notifyReward(0);
        vm.prank(ALICE);
        vm.expectRevert(CompanyStaking.InsufficientStake.selector);
        staking.unstake(1);
        _stake(ALICE, 1 ether);
        staking.notifyReward(10 ether);
        vm.prank(ALICE);
        vm.expectRevert(CompanyStaking.BatchNotClaimable.selector);
        staking.claim(BATCH);
        vm.warp(START + 1 days);
        vm.prank(ALICE);
        staking.claim(BATCH);
        vm.prank(ALICE);
        vm.expectRevert(CompanyStaking.BatchNotClaimable.selector);
        staking.claim(BATCH);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 0);
        assertEq(staking.claimable(ALICE, type(uint256).max), 0);
    }

    function test_feeOnTransferRewardsRejectedWithoutCreatingLiability() public {
        imd.configure(100, false);
        vm.expectRevert(CompanyStaking.UnsupportedToken.selector);
        staking.notifyReward(10 ether);
        assertEq(staking.rewardLiability(), 0);
        assertEq(staking.totalRewardsFunded(), 0);
        assertEq(imd.balanceOf(address(staking)), 0);
    }

    function test_stakeTokenTransferFailureAndCallback() public {
        MockERC20 other = new MockERC20("Test", "TEST", 18);
        CompanyStaking otherStaking = new CompanyStaking(
            address(other), address(imd), address(registry), FACTORY, address(venue), IMD_POOL, block.chainid
        );
        other.mint(address(this), 100 ether);
        other.approve(address(otherStaking), 100 ether);
        other.configure(100, false);
        vm.expectRevert(CompanyStaking.UnsupportedToken.selector);
        otherStaking.stake(10 ether);
        assertEq(otherStaking.totalStaked(), 0);
        other.configure(0, false);
        other.setCallback(address(otherStaking), abi.encodeCall(otherStaking.unstake, (1)));
        otherStaking.stake(10 ether);
        assertFalse(other.callbackSucceeded());
        assertEq(other.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        other.configure(0, true);
        vm.expectRevert("token transfer failed");
        otherStaking.unstake(10 ether);
        assertEq(otherStaking.totalStaked(), 10 ether);
        other.configure(0, false);
        otherStaking.unstake(10 ether);
        assertEq(otherStaking.totalStaked(), 0);
    }

    function test_idleYearsDoNotRequireWalkingMissedDays() public {
        _stake(ALICE, 100 ether);
        vm.warp(START + 3650 days);
        staking.notifyReward(10 ether);
        vm.warp(START + 3651 days);
        vm.prank(ALICE);
        uint256 beforeGas = gasleft();
        staking.unstake(100 ether);
        assertLt(beforeGas - gasleft(), 300_000);
        vm.prank(ALICE);
        beforeGas = gasleft();
        assertEq(staking.claimAll(), 10 ether);
        assertLt(beforeGas - gasleft(), 600_000);
        assertEq(staking.totalStaked(), 0);
    }

    function test_donationsAreNotPrincipalOrAccruedRewardsAndCannotBeSwept() public {
        _stake(ALICE, 10 ether);
        company.transfer(address(staking), 12 ether);
        imd.transfer(address(staking), 15 ether);
        staking.notifyReward(10 ether);
        assertEq(staking.totalStaked(), 10 ether);
        assertEq(staking.rewardLiability(), 10 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        staking.burnExpired(BATCH);
        assertEq(company.balanceOf(address(staking)), 22 ether);
        assertEq(imd.balanceOf(address(staking)), 15 ether);
        vm.prank(OWNER);
        (bool ok,) = address(staking).call(abi.encodeWithSignature("withdraw(address,uint256)", address(imd), 15 ether));
        assertFalse(ok);
        vm.prank(OWNER);
        vm.expectRevert(CompanyStaking.InsufficientStake.selector);
        staking.unstake(10 ether);
        vm.prank(OWNER);
        assertEq(staking.claimAll(), 0);
    }

    function test_endToEndVaultProfitThenClaimAndBurn() public {
        _stake(ALICE, 100 ether);
        _stake(BOB, 100 ether);
        _buy(address(nativeTarget));
        _price(5);
        vm.prank(KEEPER);
        vault.sell(address(nativeTarget));
        uint256 reward = staking.rewardLiability();
        assertGt(reward, 0);
        vm.warp(START + 1 days);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), reward / 2);
        vm.prank(ALICE);
        staking.unstake(100 ether);
        vm.warp(START + 8 days);
        _refreshRates();
        vm.prank(EVE);
        staking.burnExpired(BATCH);
        assertEq(company.balanceOf(staking.DEAD()), reward);
        assertEq(staking.rewardLiability(), 0);
        assertEq(staking.totalStaked(), 100 ether);
        assertEq(staking.totalRewardsPaid() + staking.totalImdBurned(), reward);
    }
}
