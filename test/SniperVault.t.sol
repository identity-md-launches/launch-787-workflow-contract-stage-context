// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, SniperVault, CompanyStaking, Trading, MockERC20, Math} from "./Base.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SniperVaultTest is BaseTest {
    function test_defaultsAndExplicitOwner() public view {
        assertEq(vault.owner(), OWNER);
        assertEq(vault.keeper(), KEEPER);
        assertEq(vault.maxSpendBps(), 100);
        assertEq(vault.slippageBps(), 1000);
        assertEq(vault.stakerShareBps(), 3000);
        assertEq(vault.MAX_SUPPLY_BPS(), 200);
        assertFalse(vault.paused());
    }

    function test_defaultSnipeRecordsActualInputAndOutput() public {
        uint256 beforeImd = imd.balanceOf(address(vault));
        vm.prank(KEEPER);
        vault.snipe(address(target));
        SniperVault.Position memory p = vault.positionOf(address(target));
        assertEq(p.asset, address(imd));
        assertEq(p.poolId, SNIPE_POOL);
        assertEq(p.originalAmount, target.balanceOf(address(vault)));
        assertEq(p.remainingAmount, p.originalAmount);
        assertEq(p.entryCost, beforeImd - imd.balanceOf(address(vault)));
        assertEq(p.remainingCost, p.entryCost);
        assertEq(p.entryPrice, p.entryCost * 1e18 / p.originalAmount);
        assertLe(p.entryCost, beforeImd / 100);
        assertLe(p.originalAmount, target.totalSupply() / 50);
        assertEq(vault.snipedTokenCount(), 1);
        assertEq(imd.allowance(address(vault), address(venue)), 0);
        assertEq(imd.balanceOf(KEEPER), 0);
        assertEq(target.balanceOf(KEEPER), 0);
    }

    function test_nativeSnipeRefundsUnusedMaximum() public {
        uint256 beforeEth = address(vault).balance;
        vm.prank(KEEPER);
        vault.snipe(address(nativeTarget));
        SniperVault.Position memory p = vault.positionOf(address(nativeTarget));
        assertEq(p.asset, address(0));
        assertEq(p.entryCost, beforeEth - address(vault).balance);
        assertLt(p.entryCost, beforeEth / 100);
        assertEq(p.originalAmount, nativeTarget.balanceOf(address(vault)));
        assertEq(KEEPER.balance, 0);
    }

    function test_buyCapsExactlyTwoPercentEvenWithLargeBudget() public {
        MockERC20 small = new MockERC20("Small", "SMALL", 6);
        small.mint(address(venue), 1_000_000);
        registry.setLaunch(address(small), FACTORY, address(imd), SNIPE_POOL);
        venue.setRate(SNIPE_POOL, address(imd), address(small), 1, 1e12);
        vm.prank(KEEPER);
        vault.snipe(address(small));
        assertEq(small.balanceOf(address(vault)), 20_000);
        assertEq(vault.positionOf(address(small)).entryCost, 20_000 * 1e12);
    }

    function testFuzz_buyRespectsBothCaps(uint256 balance, uint256 spendBps, uint256 supply) public {
        balance = bound(balance, 1e6, 1e24);
        spendBps = bound(spendBps, 1, 10_000);
        supply = bound(supply, 1e8, 1e28);
        MockERC20 asset = new MockERC20("Fuzz", "FZ", 18);
        asset.mint(address(venue), supply);
        registry.setLaunch(address(asset), FACTORY, address(imd), SNIPE_POOL);
        venue.setRate(SNIPE_POOL, address(imd), address(asset), 100, 1);
        vm.startPrank(OWNER);
        vault.withdraw(address(imd), imd.balanceOf(address(vault)));
        imd.mint(OWNER, balance);
        imd.approve(address(vault), balance);
        vault.depositIMD(balance);
        vault.setMaxSpendBps(spendBps);
        vm.stopPrank();
        vm.prank(KEEPER);
        vault.snipe(address(asset));
        SniperVault.Position memory p = vault.positionOf(address(asset));
        assertLe(p.originalAmount, supply * 200 / 10_000);
        assertLe(p.entryCost, balance * spendBps / 10_000);
        assertEq(imd.balanceOf(address(vault)) + p.entryCost, balance);
        assertEq(asset.balanceOf(address(vault)), p.originalAmount);
    }

    function test_duplicateRemainsForbiddenAfterFullWithdrawal() public {
        _buy(address(target));
        vm.prank(KEEPER);
        vm.expectRevert(SniperVault.AlreadySniped.selector);
        vault.snipe(address(target));
        uint256 amount = target.balanceOf(address(vault));
        vm.prank(OWNER);
        vault.withdraw(address(target), amount);
        vm.prank(KEEPER);
        vm.expectRevert(SniperVault.AlreadySniped.selector);
        vault.snipe(address(target));
    }

    function test_invalidOriginPairAndUnknownLaunchRevert() public {
        registry.setLaunch(address(target), EVE, address(imd), SNIPE_POOL);
        _expectInvalidLaunch();
        registry.setLaunch(address(target), FACTORY, address(company), SNIPE_POOL);
        _expectInvalidLaunch();
        registry.setLaunch(address(target), FACTORY, address(imd), bytes32(0));
        _expectInvalidLaunch();
        registry.setLaunch(address(target), address(0), address(0), bytes32(0));
        _expectInvalidLaunch();
        assertEq(vault.snipedTokenCount(), 0);
    }

    function _expectInvalidLaunch() private {
        vm.prank(KEEPER);
        vm.expectRevert(Trading.InvalidLaunch.selector);
        vault.snipe(address(target));
    }

    function test_wrongChainRejected() public {
        vm.chainId(block.chainid + 1);
        vm.prank(KEEPER);
        vm.expectRevert(Trading.WrongChain.selector);
        vault.snipe(address(target));
    }

    function test_pausedBlocksOnlySnipe() public {
        _buy(address(target));
        vm.prank(OWNER);
        vault.pause();
        vm.prank(KEEPER);
        vm.expectRevert(SniperVault.VaultPaused.selector);
        vault.snipe(address(nativeTarget));
        _price(5);
        vm.prank(KEEPER);
        vault.sell(address(target));
        assertEq(vault.positionOf(address(target)).nextLevel, 1);
        vm.prank(OWNER);
        vault.unpause();
        vm.prank(KEEPER);
        vault.snipe(address(nativeTarget));
    }

    function test_ownerWithdrawAllWhilePausedIncludesBoughtTokens() public {
        _buy(address(target));
        _buy(address(nativeTarget));
        uint256 bought = target.balanceOf(address(vault));
        uint256 boughtNative = nativeTarget.balanceOf(address(vault));
        vm.startPrank(OWNER);
        vault.pause();
        vault.withdrawAll();
        vm.stopPrank();
        assertEq(target.balanceOf(OWNER), bought);
        assertEq(nativeTarget.balanceOf(OWNER), boughtNative);
        assertEq(address(vault).balance, 0);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(vault.positionOf(address(target)).remainingAmount, 0);
        assertEq(vault.positionOf(address(target)).remainingCost, 0);
        vm.prank(KEEPER);
        vm.expectRevert(SniperVault.NoPosition.selector);
        vault.sell(address(target));
    }

    function test_partialWithdrawalRetiresProportionalCost() public {
        SniperVault.Position memory beforePosition = _buy(address(target));
        vm.prank(OWNER);
        vault.withdraw(address(target), beforePosition.originalAmount / 2);
        SniperVault.Position memory p = vault.positionOf(address(target));
        assertEq(p.remainingAmount, beforePosition.originalAmount / 2);
        assertEq(p.remainingCost, beforePosition.entryCost / 2);
        _price(2);
        vm.prank(OWNER);
        vault.emergencySell(address(target));
        assertEq(staking.rewardLiability(), beforePosition.entryCost / 2 * 3000 / 10_000);
        assertEq(vault.positionOf(address(target)).remainingCost, 0);
    }

    function test_allFiveLevelsAndProfitConservation() public {
        SniperVault.Position memory initial = _buy(address(target));
        uint256 totalReceived;
        uint256 totalReward;
        uint256[5] memory multipliers = [uint256(5), 10, 25, 50, 100];
        for (uint256 i; i < 5; ++i) {
            uint256 balanceBefore = imd.balanceOf(address(vault));
            uint256 stakingBefore = staking.rewardLiability();
            _price(multipliers[i]);
            vm.prank(KEEPER);
            vault.sell(address(target));
            uint256 proceeds = initial.entryCost / 5 * multipliers[i];
            uint256 reward = (proceeds - initial.entryCost / 5) * 3000 / 10_000;
            totalReceived += proceeds;
            totalReward += reward;
            SniperVault.Position memory p = vault.positionOf(address(target));
            assertEq(p.nextLevel, i + 1);
            assertEq(p.remainingAmount, initial.originalAmount - initial.originalAmount / 5 * (i + 1));
            assertEq(staking.rewardLiability() - stakingBefore, reward);
            assertEq(imd.balanceOf(address(vault)), balanceBefore + proceeds - reward);
            if (i < 4) {
                vm.prank(KEEPER);
                vm.expectRevert(SniperVault.TargetNotReached.selector);
                vault.sell(address(target));
            }
        }
        SniperVault.Position memory finished = vault.positionOf(address(target));
        assertEq(finished.proceeds, totalReceived);
        assertEq(finished.rewardsImd, totalReward);
        assertEq(finished.remainingCost, 0);
        assertEq(target.balanceOf(address(vault)), 0);
        assertEq(target.allowance(address(vault), address(venue)), 0);
        assertEq(imd.allowance(address(vault), address(staking)), 0);
        assertEq(
            imd.balanceOf(address(vault)) + imd.balanceOf(address(staking)),
            1000 ether - initial.entryCost + totalReceived
        );
        vm.prank(KEEPER);
        vm.expectRevert(SniperVault.NoPosition.selector);
        vault.sell(address(target));
        vm.prank(KEEPER);
        vm.expectRevert(SniperVault.AlreadySniped.selector);
        vault.snipe(address(target));
    }

    function test_nativeProfitIsConvertedToIMDAndFunded() public {
        SniperVault.Position memory p = _buy(address(nativeTarget));
        uint256 ethBefore = address(vault).balance;
        uint256 imdBefore = imd.balanceOf(address(vault));
        _price(5);
        vm.prank(KEEPER);
        vault.sell(address(nativeTarget));
        uint256 proceeds = p.entryCost;
        uint256 ethShare = (proceeds - p.entryCost / 5) * 3000 / 10_000;
        assertEq(staking.rewardLiability(), ethShare * 1000);
        assertEq(address(vault).balance, ethBefore + proceeds - ethShare);
        assertEq(imd.balanceOf(address(vault)), imdBefore);
        assertEq(imd.balanceOf(address(staking)), ethShare * 1000);
    }

    function test_conversionFailureRollsBackEntireSale() public {
        SniperVault.Position memory p = _buy(address(nativeTarget));
        _price(5);
        venue.configure(10_000, false, IMD_POOL);
        uint256 nativeBalance = address(vault).balance;
        vm.prank(KEEPER);
        vm.expectRevert("swap failed");
        vault.sell(address(nativeTarget));
        assertEq(address(vault).balance, nativeBalance);
        assertEq(vault.positionOf(address(nativeTarget)).remainingAmount, p.originalAmount);
        assertEq(vault.positionOf(address(nativeTarget)).nextLevel, 0);
        assertEq(staking.rewardLiability(), 0);
    }

    function test_emergencySaleLossPaysNoRewardAndWorksPaused() public {
        SniperVault.Position memory p = _buy(address(target));
        venue.setRate(SNIPE_POOL, address(target), address(imd), 1, 200);
        vm.startPrank(OWNER);
        vault.pause();
        vault.emergencySell(address(target));
        vm.stopPrank();
        assertEq(vault.positionOf(address(target)).remainingAmount, 0);
        assertEq(vault.positionOf(address(target)).proceeds, p.entryCost / 2);
        assertEq(staking.rewardLiability(), 0);
    }

    function test_saleCannotExecuteBelowActualLadderTarget() public {
        SniperVault.Position memory p = _buy(address(target));
        vm.prank(OWNER);
        vault.setSlippageBps(1000);
        _price(5);
        venue.configure(9500, false, bytes32(0));
        vm.prank(KEEPER);
        vm.expectRevert("slippage");
        vault.sell(address(target));
        assertEq(vault.positionOf(address(target)).remainingAmount, p.originalAmount);
        assertEq(vault.positionOf(address(target)).nextLevel, 0);
    }

    function test_snipeFailureAndDishonestUnderDeliveryLeaveNoPositionOrAllowance() public {
        venue.configure(10_000, true, bytes32(0));
        vm.prank(KEEPER);
        vm.expectRevert(Trading.SwapAccounting.selector);
        vault.snipe(address(target));
        assertEq(vault.snipedTokenCount(), 0);
        assertEq(imd.balanceOf(address(vault)), 1000 ether);
        assertEq(imd.allowance(address(vault), address(venue)), 0);
        venue.configure(8000, false, bytes32(0));
        vm.prank(KEEPER);
        vm.expectRevert("slippage");
        vault.snipe(address(target));
        venue.configure(10_000, false, bytes32(0));
        vm.prank(KEEPER);
        vault.snipe(address(target));
    }

    function test_underDeliveringSaleRollsBack() public {
        SniperVault.Position memory p = _buy(address(target));
        _price(10);
        venue.configure(10_000, true, bytes32(0));
        vm.prank(KEEPER);
        vm.expectRevert(Trading.SwapAccounting.selector);
        vault.sell(address(target));
        assertEq(vault.positionOf(address(target)).remainingAmount, p.originalAmount);
        assertEq(staking.rewardLiability(), 0);
    }

    function test_staleFutureAndZeroQuotesRejected() public {
        venue.setTimestamp(SNIPE_POOL, address(imd), address(target), START - 901);
        _expectBadQuote();
        venue.setTimestamp(SNIPE_POOL, address(imd), address(target), START + 1);
        _expectBadQuote();
        venue.setRate(SNIPE_POOL, address(imd), address(target), 0, 1);
        _expectBadQuote();
    }

    function _expectBadQuote() private {
        vm.prank(KEEPER);
        vm.expectRevert(Trading.InvalidQuote.selector);
        vault.snipe(address(target));
    }

    function test_feeOnTransferFundingAndPurchaseRejected() public {
        imd.configure(100, false);
        vm.startPrank(OWNER);
        imd.approve(address(vault), 1 ether);
        vm.expectRevert(SniperVault.UnsupportedToken.selector);
        vault.depositIMD(1 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(vault)), 1000 ether);
        imd.configure(0, false);
        target.configure(100, false);
        vm.prank(KEEPER);
        vm.expectRevert(Trading.SwapAccounting.selector);
        vault.snipe(address(target));
        assertEq(vault.snipedTokenCount(), 0);
    }

    function test_reentrantKeeperCannotSnipeAgainDuringSwap() public {
        vm.prank(OWNER);
        vault.setKeeper(address(venue));
        venue.setCallback(address(vault), abi.encodeCall(vault.snipe, (address(nativeTarget))));
        vm.prank(address(venue));
        vault.snipe(address(target));
        assertFalse(venue.callbackSucceeded());
        assertEq(venue.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(vault.snipedTokenCount(), 1);
    }

    function test_keeperAndStrangerCannotUseAnyOwnerFunction() public {
        uint32[5] memory multiples = [uint32(5), 10, 25, 50, 100];
        uint16[5] memory fractions = [uint16(2000), 2000, 2000, 2000, 2000];
        bytes[12] memory calls = [
            abi.encodeCall(vault.depositIMD, (1)),
            abi.encodeCall(vault.depositETH, ()),
            abi.encodeCall(vault.withdraw, (address(imd), 1)),
            abi.encodeCall(vault.withdrawAll, ()),
            abi.encodeCall(vault.pause, ()),
            abi.encodeCall(vault.unpause, ()),
            abi.encodeCall(vault.setKeeper, (EVE)),
            abi.encodeCall(vault.setMaxSpendBps, (200)),
            abi.encodeCall(vault.setSlippageBps, (200)),
            abi.encodeCall(vault.setLadder, (multiples, fractions)),
            abi.encodeCall(vault.setStakerShareBps, (200)),
            abi.encodeCall(vault.emergencySell, (address(target)))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(KEEPER);
            (bool ok, bytes memory reason) = address(vault).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(SniperVault.Unauthorized.selector));
            vm.prank(EVE);
            (ok,) = address(vault).call(calls[i]);
            assertFalse(ok);
        }
        vm.prank(OWNER);
        vm.expectRevert(SniperVault.Unauthorized.selector);
        vault.snipe(address(target));
        vm.prank(EVE);
        vm.expectRevert(SniperVault.Unauthorized.selector);
        vault.sell(address(target));
        assertEq(address(vault).balance, 10 ether);
        assertEq(imd.balanceOf(address(vault)), 1000 ether);
    }

    function test_keeperRevocation() public {
        vm.prank(OWNER);
        vault.setKeeper(address(0));
        vm.prank(KEEPER);
        vm.expectRevert(SniperVault.Unauthorized.selector);
        vault.snipe(address(target));
    }

    function test_parameterBoundsAndFutureOnlyLadder() public {
        _buy(address(target));
        vm.startPrank(OWNER);
        vm.expectRevert(SniperVault.InvalidParameters.selector);
        vault.setMaxSpendBps(0);
        vm.expectRevert(SniperVault.InvalidParameters.selector);
        vault.setMaxSpendBps(10_001);
        vm.expectRevert(SniperVault.InvalidParameters.selector);
        vault.setSlippageBps(10_000);
        vm.expectRevert(SniperVault.InvalidParameters.selector);
        vault.setStakerShareBps(5001);
        uint32[5] memory multiples = [uint32(2), 3, 4, 5, 6];
        uint16[5] memory fractions = [uint16(1000), 1000, 1000, 1000, 6000];
        vault.setLadder(multiples, fractions);
        vault.setStakerShareBps(5000);
        vault.setMaxSpendBps(10_000);
        fractions[0] = 0;
        vm.expectRevert(SniperVault.InvalidParameters.selector);
        vault.setLadder(multiples, fractions);
        fractions[0] = 1001;
        vm.expectRevert(SniperVault.InvalidParameters.selector);
        vault.setLadder(multiples, fractions);
        fractions[0] = 1000;
        multiples[1] = 2;
        vm.expectRevert(SniperVault.InvalidParameters.selector);
        vault.setLadder(multiples, fractions);
        vm.stopPrank();
        SniperVault.Position memory p = vault.positionOf(address(target));
        assertEq(p.multiples[0], 5);
        assertEq(p.sellBps[0], 2000);
        vm.prank(KEEPER);
        vault.snipe(address(nativeTarget));
        p = vault.positionOf(address(nativeTarget));
        assertEq(p.multiples[0], 2);
        assertEq(p.sellBps[0], 1000);
    }

    function test_rewardFundingFailureRollsBackSale() public {
        SniperVault.Position memory p = _buy(address(target));
        _price(5);
        // Proceeds can reach the vault, but the reward transfer to staking must fail atomically.
        imd.setBlockedRecipient(address(staking));
        vm.prank(KEEPER);
        vm.expectRevert("recipient blocked");
        vault.sell(address(target));
        assertEq(vault.positionOf(address(target)).remainingAmount, p.originalAmount);
        assertEq(vault.positionOf(address(target)).nextLevel, 0);
        assertEq(staking.rewardLiability(), 0);
        assertEq(imd.allowance(address(vault), address(staking)), 0);
        assertEq(imd.balanceOf(address(vault)), 1000 ether - p.entryCost);
    }

    function test_ownerSaleAndZeroProfitShare() public {
        _buy(address(target));
        _price(5);
        vm.startPrank(OWNER);
        vault.setStakerShareBps(0);
        vault.sell(address(target));
        vm.stopPrank();
        assertEq(staking.rewardLiability(), 0);
        assertEq(vault.positionOf(address(target)).nextLevel, 1);
    }
}
