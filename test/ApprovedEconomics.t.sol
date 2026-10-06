// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, SniperVault, MockERC20} from "./Base.t.sol";

// Reproduced advisory observations match the approved ownership, daily weighting and spend model.
contract ApprovedEconomicsTest is BaseTest {
    function test_reproPostFundingStakeSharesWholeDay() public {
        _stake(ALICE, 100_000 ether);
        vm.warp(START + 10 minutes);
        staking.notifyReward(10_000 ether);
        company.transfer(EVE, 10_000_000 ether);
        vm.startPrank(EVE);
        company.approve(address(staking), type(uint256).max);
        vm.warp(START + 11 minutes);
        staking.stake(10_000_000 ether);
        vm.stopPrank();
        vm.warp(START + 1 days);
        assertGt(staking.claimable(EVE, BATCH), 9000 ether);
        assertLt(staking.claimable(ALICE, BATCH), 1000 ether);
    }

    function test_reproOwnerCanZeroShareAndWithdrawInventory() public {
        _stake(ALICE, 100_000 ether);
        SniperVault.Position memory p = _buy(address(target));
        _price(5);
        vm.startPrank(OWNER);
        vault.setStakerShareBps(0);
        vault.sell(address(target));
        vault.withdraw(address(target), p.originalAmount * 4 / 5);
        vm.stopPrank();
        assertEq(staking.totalRewardsFunded(), 0);
        assertGt(vault.positionOf(address(target)).proceeds, 0);
        assertEq(vault.positionOf(address(target)).remainingAmount, 0);
    }

    function test_reproKeeperSpendIsPerPurchase() public {
        vm.startPrank(OWNER);
        vault.setMaxSpendBps(1000);
        vault.setSlippageBps(0);
        vm.stopPrank();
        for (uint256 i; i < 20; ++i) {
            MockERC20 token = new MockERC20("Launch", "NEW", 18);
            token.mint(address(venue), 1e27);
            registry.setLaunch(address(token), FACTORY, address(imd), SNIPE_POOL);
            venue.setRate(SNIPE_POOL, address(imd), address(token), 100, 1);
            vm.prank(KEEPER);
            vault.snipe(address(token));
        }
        assertLt(imd.balanceOf(address(vault)), 150 ether);
        assertEq(vault.snipedTokenCount(), 20);
    }
}
