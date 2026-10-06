// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, CompanyStaking, LaunchToken, MockERC20, MockVenue, Math, Trading} from "./Base.t.sol";
import {Test} from "forge-std/Test.sol";

/// @dev The oracle integrates each time interval into calendar days. It does not use
/// the implementation's checkpoint/prefix-sum algorithm or claimable() as an oracle.
contract StakingSequenceHandler is Test {
    CompanyStaking public immutable staking;
    LaunchToken public immutable company;
    MockERC20 public immutable imd;
    MockVenue public immutable venue;
    bytes32 private immutable pool;
    uint256 public immutable firstDay;
    address[3] public actors;
    uint256[3] public principal;
    uint256[3] public paidTo;
    uint256[3] private initialBalances;
    mapping(uint256 => uint256[3]) private weights;
    mapping(uint256 => uint256) public funded;
    mapping(uint256 => uint256) public paid;
    mapping(uint256 => bool[3]) private didClaim;
    mapping(uint256 => bool) public didBurn;
    uint256[] public fundedDays;
    uint256 public totalFunded;
    uint256 public totalPaid;
    uint256 public burnedImd;
    uint256 public burnedCompany;
    uint256 public retiredDust;
    uint256 public donatedCompany;
    uint256 public donatedImd;

    constructor(CompanyStaking staking_, MockVenue venue_, bytes32 pool_, address[3] memory actors_) {
        staking = staking_;
        company = LaunchToken(staking_.company());
        imd = MockERC20(staking_.imd());
        venue = venue_;
        pool = pool_;
        firstDay = block.timestamp / 1 days;
        actors = actors_;
        imd.approve(address(staking), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            initialBalances[i] = company.balanceOf(actors[i]);
            vm.prank(actors[i]);
            company.approve(address(staking), type(uint256).max);
        }
    }

    function stake(uint256 who, uint256 amount) public {
        who %= 3;
        uint256 available = initialBalances[who] - principal[who];
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actors[who]);
        staking.stake(amount);
        principal[who] += amount;
    }

    function unstake(uint256 who, uint256 amount) public {
        who %= 3;
        if (principal[who] == 0) {
            vm.prank(actors[who]);
            vm.expectRevert(CompanyStaking.InsufficientStake.selector);
            staking.unstake(1);
            return;
        }
        amount = bound(amount, 1, principal[who]);
        vm.prank(actors[who]);
        staking.unstake(amount);
        principal[who] -= amount;
    }

    function fund(uint256 amount) public {
        amount = bound(amount, 1, 1000 ether);
        uint256 day = block.timestamp / 1 days;
        staking.notifyReward(amount);
        if (funded[day] == 0) fundedDays.push(day);
        funded[day] += amount;
        totalFunded += amount;
    }

    function elapse(uint256 seconds_) public {
        uint256 from = block.timestamp;
        uint256 to = from + bound(seconds_, 0, 3 days);
        while (from < to) {
            uint256 day = from / 1 days;
            uint256 end = Math.min(to, (day + 1) * 1 days);
            for (uint256 i; i < 3; ++i) {
                weights[day][i] += principal[i] * (end - from);
            }
            from = end;
        }
        vm.warp(to);
    }

    function claimAll(uint256 who) public {
        who %= 3;
        uint256 today = block.timestamp / 1 days;
        uint256 start = Math.max(firstDay, today - 7);
        uint256 expected;
        for (uint256 day = start; day < today; ++day) {
            expected += _recordClaim(who, day);
        }
        vm.prank(actors[who]);
        assertEq(staking.claimAll(), expected, "time-weighted reward differs from interval oracle");
    }

    function claimOne(uint256 who, uint256 daySeed) public {
        who %= 3;
        uint256 today = block.timestamp / 1 days;
        uint256 day = bound(daySeed, firstDay - 1, today + 1);
        if (day < firstDay || day >= today || today - day > 7 || didClaim[day][who]) {
            vm.prank(actors[who]);
            vm.expectRevert(CompanyStaking.BatchNotClaimable.selector);
            staking.claim(day);
        } else {
            uint256 expected = _recordClaim(who, day);
            vm.prank(actors[who]);
            assertEq(staking.claim(day), expected, "single claim differs from interval oracle");
        }
    }

    function burn(uint256 seed) public {
        _burn(seed, false, false);
    }

    function burnFractional(uint256 seed, bool stale) public {
        _burn(seed, true, stale);
    }

    function _burn(uint256 seed, bool fractional, bool stale) private {
        if (fundedDays.length == 0) return;
        uint256 day = fundedDays[seed % fundedDays.length];
        if (didBurn[day]) {
            vm.expectRevert(CompanyStaking.BatchAlreadyBurned.selector);
            staking.burnExpired(day);
        } else if (block.timestamp < (day + 8) * 1 days) {
            vm.expectRevert(CompanyStaking.BatchNotExpired.selector);
            staking.burnExpired(day);
        } else {
            venue.setRate(pool, address(imd), address(company), fractional ? 1 : 2, fractional ? 10 : 1);
            uint256 amount = funded[day] - paid[day];
            if (stale && amount != 0) {
                venue.setTimestamp(pool, address(imd), address(company), 0);
                vm.prank(actors[seed % 3]);
                vm.expectRevert(Trading.InvalidQuote.selector);
                staking.burnExpired(day);
                assertAccounting();
                return;
            }
            uint256 expected = fractional ? amount / 10 : amount * 2;
            vm.prank(actors[seed % 3]);
            assertEq(staking.burnExpired(day), expected, "burn output");
            didBurn[day] = true;
            if (expected == 0) retiredDust += amount;
            else burnedImd += amount;
            burnedCompany += expected;
        }
    }

    function donate(uint256 amount, bool rewardToken) public {
        amount = bound(amount, 1, 100 ether);
        if (rewardToken) {
            imd.transfer(address(staking), amount);
            donatedImd += amount;
        } else {
            company.transfer(address(staking), amount);
            donatedCompany += amount;
        }
    }

    function roundTrip(uint256 who, uint256 amount) public {
        who %= 3;
        uint256 available = initialBalances[who] - principal[who];
        if (available == 0) return;
        amount = bound(amount, 1, available);
        uint256 beforeBalance = company.balanceOf(actors[who]);
        vm.startPrank(actors[who]);
        for (uint256 i; i < 3; ++i) {
            staking.stake(amount);
            staking.unstake(amount);
        }
        vm.stopPrank();
        assertEq(company.balanceOf(actors[who]), beforeBalance, "round trip extracted principal");
        // The interval oracle deliberately records no stake-seconds for these zero-duration cycles.
    }

    function _entitlement(uint256 who, uint256 day) private view returns (uint256) {
        if (didClaim[day][who] || didBurn[day]) return 0;
        uint256 aggregate = weights[day][0] + weights[day][1] + weights[day][2];
        return aggregate == 0 ? 0 : Math.mulDiv(funded[day], weights[day][who], aggregate);
    }

    function _recordClaim(uint256 who, uint256 day) private returns (uint256 amount) {
        amount = _entitlement(who, day);
        didClaim[day][who] = true;
        paid[day] += amount;
        paidTo[who] += amount;
        totalPaid += amount;
    }

    function assertAccounting() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += principal[i];
            assertEq(staking.balanceOf(actors[i]), principal[i], "actor principal");
            assertEq(company.balanceOf(actors[i]) + principal[i], initialBalances[i], "principal round-trip backing");
            assertEq(imd.balanceOf(actors[i]), paidTo[i], "actual recipient rewards");
        }
        assertEq(staking.totalStaked(), sum, "sum of stakes");
        assertEq(company.balanceOf(address(staking)), sum + donatedCompany, "principal and donation backing");
        uint256 liability = totalFunded - totalPaid - burnedImd - retiredDust;
        assertEq(staking.rewardLiability(), liability, "funded = paid + burned + dust + owed");
        assertEq(imd.balanceOf(address(staking)), liability + donatedImd + retiredDust, "reward and dust backing");
        assertEq(staking.totalRewardsFunded(), totalFunded);
        assertEq(staking.totalRewardsPaid(), totalPaid);
        assertEq(staking.totalImdBurned(), burnedImd);
        assertEq(staking.totalImdDust(), retiredDust);
        assertEq(company.balanceOf(staking.DEAD()), burnedCompany);
        assertEq(staking.totalCompanyBurned(), burnedCompany);
        assertEq(imd.allowance(address(staking), address(venue)), 0, "no residual router approval");

        uint256 today = block.timestamp / 1 days;
        uint256 batchLiability;
        for (uint256 n; n < fundedDays.length; ++n) {
            uint256 day = fundedDays[n];
            (uint256 actualFunded, uint256 actualPaid, bool burned) = staking.batches(day);
            assertEq(actualFunded, funded[day]);
            assertEq(actualPaid, paid[day]);
            assertEq(burned, didBurn[day]);
            assertLe(actualPaid, actualFunded, "batch overpayment");
            if (!burned) batchLiability += actualFunded - actualPaid;
            for (uint256 i; i < 3; ++i) {
                assertEq(staking.claimed(day, actors[i]), didClaim[day][i]);
                if (day < today) {
                    (uint256 personal, uint256 aggregate) = staking.stakeSeconds(actors[i], day);
                    assertEq(personal, weights[day][i], "historical personal weight");
                    assertEq(aggregate, weights[day][0] + weights[day][1] + weights[day][2], "aggregate weight");
                }
                uint256 expected = day < today && today - day <= 7 ? _entitlement(i, day) : 0;
                assertEq(staking.claimable(actors[i], day), expected, "claimable oracle");
            }
        }
        assertEq(batchLiability, liability, "sum of batch obligations");
    }

    /// @dev A sequence must leave every actor able to recover all principal; then all
    /// remaining reward liabilities must settle, including expired batches and dust.
    function exitAndSettle() public {
        for (uint256 i; i < 3; ++i) {
            if (principal[i] != 0) unstake(i, principal[i]);
            claimAll(i);
        }
        elapse(3 days);
        elapse(3 days);
        elapse(3 days);
        for (uint256 i; i < fundedDays.length; ++i) {
            burn(i);
        }
        assertAccounting();
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.rewardLiability(), 0);
    }
}

contract CompanyStakingInvariantTest is BaseTest {
    StakingSequenceHandler private handler;

    function setUp() public override {
        super.setUp();
        company.transfer(EVE, 100_000 ether);
        handler = new StakingSequenceHandler(staking, venue, COMPANY_POOL, [ALICE, BOB, EVE]);
        company.transfer(address(handler), 1_000_000 ether);
        imd.mint(address(handler), 1_000_000 ether);
        handler.stake(0, 10 ether);
        handler.fund(100 ether);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.elapse.selector;
        selectors[4] = handler.claimAll.selector;
        selectors[5] = handler.claimOne.selector;
        selectors[6] = handler.burn.selector;
        selectors[7] = handler.donate.selector;
        selectors[8] = handler.roundTrip.selector;
        selectors[9] = handler.burnFractional.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_principalRewardsAndDailyWeightsMatchIndependentModel() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.exitAndSettle();
    }

    function test_handlerExercisesClaimsBurnsDonationsAndRoundTrips() public {
        handler.elapse(12 hours);
        handler.stake(1, 10 ether);
        handler.roundTrip(2, 1);
        handler.donate(7, false);
        handler.donate(11, true);
        handler.elapse(12 hours);
        handler.claimAll(0);
        handler.claimOne(0, BATCH); // Duplicate must fail without changing the model.
        handler.fund(123);
        handler.assertAccounting();
        handler.exitAndSettle();
        assertGt(handler.totalPaid(), 0);
        assertGt(handler.burnedImd(), 0);
    }

    function test_handlerRetainsDustWithoutSpendingOtherBatchesOrDonations() public {
        handler.elapse(1 days);
        handler.claimAll(0); // Settle the initial large batch.
        handler.unstake(0, 10 ether);
        handler.fund(9); // Below one COMPANY minor unit at the fractional quote.
        handler.donate(11, true);
        handler.donate(7, false);
        handler.elapse(3 days);
        handler.elapse(3 days);
        handler.elapse(2 days);
        handler.fund(100); // New, unexpired liability alongside expired dust.
        handler.burnFractional(1, true); // Stale zero-output quote must keep the liability.
        assertEq(handler.retiredDust(), 0);
        assertEq(staking.rewardLiability(), 109);
        handler.burnFractional(1, false);
        assertEq(handler.retiredDust(), 9);
        assertEq(staking.rewardLiability(), 100);
        handler.burn(1); // Retired batch cannot reopen even at a better price.
        handler.exitAndSettle();
        assertEq(imd.balanceOf(address(staking)), 20); // Donation plus permanently retained dust.
        assertEq(company.balanceOf(address(staking)), 7);
        assertEq(handler.burnedImd(), 100);
        assertEq(handler.burnedCompany(), 200);
    }
}
