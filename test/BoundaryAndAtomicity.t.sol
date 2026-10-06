// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, SniperVault, CompanyStaking, Trading, MockERC20} from "./Base.t.sol";
import {ITradingVenue} from "src/interfaces/ITradingVenue.sol";

contract BoundaryAndAtomicityTest is BaseTest {
    function test_quoteAgeExactlyFifteenMinutesAcceptedThenRejected() public {
        vm.warp(START + 900);
        vm.prank(KEEPER);
        vault.snipe(address(target));
        assertGt(target.balanceOf(address(vault)), 0);
        vm.warp(START + 901);
        vm.prank(KEEPER);
        vm.expectRevert(Trading.InvalidQuote.selector);
        vault.snipe(address(nativeTarget));
        assertEq(vault.positionOf(address(nativeTarget)).originalAmount, 0);
        assertEq(address(vault).balance, 10 ether);
    }

    function test_exactOutputQuoteIsValidatedIndependentlyOfFreshInputQuote() public {
        uint256[4] memory timestamps = [uint256(0), START + 1, START - 901, START];
        for (uint256 i; i < 4; ++i) {
            vm.mockCall(
                address(venue),
                abi.encodeWithSelector(ITradingVenue.quoteExactOutput.selector),
                abi.encode(i == 3 ? uint256(0) : uint256(1), timestamps[i])
            );
            vm.prank(KEEPER);
            vm.expectRevert(Trading.InvalidQuote.selector);
            vault.snipe(address(target));
            assertEq(vault.snipedTokenCount(), 0);
            assertEq(vault.positionOf(address(target)).originalAmount, 0);
            assertEq(imd.balanceOf(address(vault)), 1000 ether);
            assertEq(imd.allowance(address(vault), address(venue)), 0);
        }
        vm.clearMockedCalls();
        vm.prank(KEEPER);
        vault.snipe(address(target));
        assertGt(vault.positionOf(address(target)).originalAmount, 0);
    }

    function test_supplyBelowFiftyMinorUnitsCannotBuyEvenOne() public {
        MockERC20 small = new MockERC20("Small", "S", 0);
        small.mint(address(venue), 49);
        registry.setLaunch(address(small), FACTORY, address(imd), SNIPE_POOL);
        venue.setRate(SNIPE_POOL, address(imd), address(small), 1, 1);
        vm.prank(KEEPER);
        vm.expectRevert(Trading.ZeroAmount.selector);
        vault.snipe(address(small));
        assertEq(vault.snipedTokenCount(), 0);
        assertEq(imd.balanceOf(address(vault)), 1000 ether);
    }

    function test_oneMinorUnitPositionSkipsEmptyTranchesAndClosesAtLastLevel() public {
        _smallLadder(1, 3000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_smallLadderConservesRemainderAndRoundsRewardByAtMostOnePerSale(uint256 amount, uint256 share)
        public
    {
        _smallLadder(bound(amount, 1, 1000), bound(share, 0, 5000));
    }

    function _smallLadder(uint256 amount, uint256 share) private {
        MockERC20 small = new MockERC20("Small", "S", 0);
        small.mint(address(venue), amount * 50);
        registry.setLaunch(address(small), FACTORY, address(imd), SNIPE_POOL);
        venue.setRate(SNIPE_POOL, address(imd), address(small), 1, 1);
        venue.setRate(SNIPE_POOL, address(small), address(imd), 150, 1);
        vm.startPrank(OWNER);
        vault.setSlippageBps(0);
        vault.setStakerShareBps(share);
        vm.stopPrank();
        vm.prank(KEEPER);
        vault.snipe(address(small));
        assertEq(small.balanceOf(address(vault)), amount);
        uint256 calls;
        while (vault.positionOf(address(small)).remainingAmount != 0 && calls < 5) {
            vm.prank(KEEPER);
            vault.sell(address(small));
            ++calls;
        }
        SniperVault.Position memory p = vault.positionOf(address(small));
        assertEq(p.remainingAmount, 0, "last tranche clears every minor unit");
        assertEq(p.remainingCost, 0);
        assertEq(p.nextLevel, 5);
        assertEq(small.balanceOf(address(vault)), 0);
        assertEq(p.proceeds, amount * 150);
        uint256 fullProfitShare = amount * 149 * share / 10_000;
        assertLe(p.rewardsImd, fullProfitShare);
        assertLt(fullProfitShare - p.rewardsImd, calls, "only per-sale floor dust may remain");
        assertEq(imd.balanceOf(address(vault)) + imd.balanceOf(address(staking)), 1000 ether + amount * 149);
        vm.prank(KEEPER);
        vm.expectRevert(SniperVault.NoPosition.selector);
        vault.sell(address(small));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_withdrawThenSellAtEntryPriceCannotDistributeProfit(uint256 withdrawn) public {
        SniperVault.Position memory p = _buy(address(target));
        withdrawn = bound(withdrawn, 0, p.originalAmount - 100);
        vm.startPrank(OWNER);
        if (withdrawn != 0) vault.withdraw(address(target), withdrawn);
        vault.emergencySell(address(target));
        vm.stopPrank();
        assertEq(staking.totalRewardsFunded(), 0, "selling at entry cannot create profit");
        assertEq(target.balanceOf(OWNER), withdrawn);
        assertEq(target.balanceOf(address(vault)), 0);
        assertEq(vault.positionOf(address(target)).remainingCost, 0);
    }

    function test_failedStakeLeavesNoHistoricalWeightOrRewardEntitlement() public {
        _stake(ALICE, 10 ether);
        vm.warp(START + 12 hours);
        company.transfer(EVE, 100 ether);
        vm.prank(EVE);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(staking), 0, 100 ether
            )
        );
        staking.stake(100 ether);
        staking.notifyReward(99 ether);
        vm.warp(START + 1 days);
        (uint256 personal, uint256 aggregate) = staking.stakeSeconds(EVE, BATCH);
        assertEq(personal, 0);
        assertEq(aggregate, 10 ether * 1 days);
        assertEq(staking.balanceOf(EVE), 0);
        vm.prank(EVE);
        assertEq(staking.claimAll(), 0);
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 99 ether);
    }

    function test_failedMultiBatchClaimRollsBackEveryClaimMarkerAndCanRetry() public {
        _stake(ALICE, 1 ether);
        for (uint256 i; i < 3; ++i) {
            vm.warp(START + i * 1 days);
            staking.notifyReward((i + 1) * 1 ether);
        }
        vm.warp(START + 3 days);
        imd.setBlockedRecipient(ALICE);
        vm.prank(ALICE);
        vm.expectRevert("recipient blocked");
        staking.claimAll();
        for (uint256 i; i < 3; ++i) {
            assertFalse(staking.claimed(BATCH + i, ALICE));
            (, uint256 paid,) = staking.batches(BATCH + i);
            assertEq(paid, 0);
        }
        assertEq(staking.rewardLiability(), 6 ether);
        assertEq(staking.totalRewardsPaid(), 0);
        imd.setBlockedRecipient(address(0));
        vm.prank(ALICE);
        assertEq(staking.claimAll(), 6 ether);
        assertEq(imd.balanceOf(ALICE), 6 ether);
    }

    function test_maximumInvalidAmountsLeaveDepositsAndPositionsIntact() public {
        _stake(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(CompanyStaking.InsufficientStake.selector);
        staking.unstake(type(uint256).max);
        vm.startPrank(OWNER);
        imd.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", OWNER, imd.balanceOf(OWNER), type(uint256).max
            )
        );
        vault.depositIMD(type(uint256).max);
        vm.expectRevert(Trading.ZeroAmount.selector);
        vault.withdraw(address(imd), 0);
        vm.expectRevert(Trading.ZeroAmount.selector);
        vault.depositETH();
        vm.stopPrank();
        assertEq(staking.totalStaked(), 1);
        assertEq(company.balanceOf(address(staking)), 1);
        assertEq(imd.balanceOf(address(vault)), 1000 ether);
        assertEq(address(vault).balance, 10 ether);
    }

    function test_sixDecimalFundingAssetBuyProfitDistributionAndClaim() public {
        MockERC20 six = new MockERC20("Six decimal IMD", "IMD6", 6);
        CompanyStaking localStaking = new CompanyStaking(
            address(company), address(six), address(registry), FACTORY, address(venue), IMD_POOL, block.chainid
        );
        SniperVault localVault = new SniperVault(OWNER, address(localStaking));
        six.mint(OWNER, 1000e6);
        six.mint(address(venue), 1_000_000e6);
        registry.setLaunch(address(target), FACTORY, address(six), SNIPE_POOL);
        venue.setRate(SNIPE_POOL, address(six), address(target), 1e14, 1);
        venue.setRate(SNIPE_POOL, address(target), address(six), 5, 1e14);
        vm.startPrank(OWNER);
        six.approve(address(localVault), 1000e6);
        localVault.depositIMD(1000e6);
        localVault.setKeeper(KEEPER);
        localVault.setSlippageBps(0);
        vm.stopPrank();
        vm.startPrank(ALICE);
        company.approve(address(localStaking), 1 ether);
        localStaking.stake(1 ether);
        vm.stopPrank();
        vm.startPrank(KEEPER);
        localVault.snipe(address(target));
        localVault.sell(address(target));
        vm.stopPrank();
        assertEq(localVault.positionOf(address(target)).entryCost, 10e6);
        assertEq(localVault.positionOf(address(target)).originalAmount, 1000 ether);
        assertEq(localStaking.rewardLiability(), 2_400_000);
        assertEq(six.balanceOf(address(localVault)), 997_600_000);
        vm.warp(START + 1 days);
        vm.prank(ALICE);
        assertEq(localStaking.claimAll(), 2_400_000);
        assertEq(six.balanceOf(ALICE), 2_400_000);
        assertEq(localStaking.rewardLiability(), 0);
    }
}
