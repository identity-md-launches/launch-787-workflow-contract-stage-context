// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, SniperVault, CompanyStaking, Trading, MockERC20, MockRegistry, MockVenue, Math} from "./Base.t.sol";
import {Test} from "forge-std/Test.sol";

contract VaultSequenceHandler is Test {
    struct Holding {
        MockERC20 token;
        uint256 bought;
        uint256 cost;
        uint256 sold;
        uint256 withdrawn;
        uint256 retired;
        uint256 donated;
        uint256 proceeds;
        uint256 rewards;
        uint256 lastCost;
        uint8 lastLevel;
        bytes32 policy;
        bool closed;
    }

    SniperVault public immutable vault;
    CompanyStaking public immutable staking;
    MockERC20 public immutable imd;
    MockRegistry public immutable registry;
    MockVenue public immutable venue;
    address private immutable owner;
    address private immutable keeper;
    address private immutable outsider;
    Holding[] private holdings;
    mapping(address => uint256) public cashIn;
    mapping(address => uint256) public cashOut;
    uint256 public successfulSales;
    uint256 public ownerWithdrawals;

    constructor(SniperVault vault_, address keeper_, address outsider_) {
        vault = vault_;
        staking = vault_.staking();
        imd = MockERC20(vault_.imd());
        registry = MockRegistry(address(vault_.registry()));
        venue = MockVenue(payable(address(vault_.venue())));
        owner = vault_.owner();
        keeper = keeper_;
        outsider = outsider_;
        cashIn[address(imd)] = imd.balanceOf(address(vault));
        cashIn[address(0)] = address(vault).balance;
        vm.prank(owner);
        imd.approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 amount, bool nativeAsset) public {
        amount = bound(amount, 1, 100 ether);
        vm.startPrank(owner);
        if (nativeAsset) vault.depositETH{value: amount}();
        else vault.depositIMD(amount);
        vm.stopPrank();
        cashIn[nativeAsset ? address(0) : address(imd)] += amount;
    }

    function configure(uint256 spend, uint256 slippage, uint256 share, bool pause_, bool disableKeeper) public {
        vm.startPrank(owner);
        vault.setMaxSpendBps(bound(spend, 1, 10_000));
        vault.setSlippageBps(bound(slippage, 0, 9999));
        vault.setStakerShareBps(bound(share, 0, 5000));
        vault.setKeeper(disableKeeper ? address(0) : keeper);
        if (pause_) vault.pause();
        else vault.unpause();
        vm.stopPrank();
    }

    function snipe(uint256 supply, bool nativeAsset) public {
        // Twelve distinct launches leave ample opportunities in a 64-call sequence.
        if (holdings.length == 12) return;
        MockERC20 token = new MockERC20("Sequence launch", "SEQ", 18);
        supply = bound(supply, 50, 1e26);
        token.mint(address(venue), supply);
        address asset = nativeAsset ? address(0) : address(imd);
        bytes32 pool = keccak256(abi.encode(address(token)));
        registry.setLaunch(address(token), vault.launchFactory(), asset, pool);
        // One minor unit of either funding asset buys one minor unit of this launch.
        venue.setRate(pool, asset, address(token), 1, 1);
        uint256 beforeBalance = _balance(asset);
        uint256 budget = beforeBalance * vault.maxSpendBps() / 10_000;
        bytes4 reason;
        if (vault.keeper() != keeper) {
            reason = SniperVault.Unauthorized.selector;
        } else if (vault.paused()) {
            reason = SniperVault.VaultPaused.selector;
        } else if (budget == 0 || budget * 10_000 / (10_000 + vault.slippageBps()) == 0) {
            reason = Trading.ZeroAmount.selector;
        }
        if (reason != bytes4(0)) {
            vm.prank(keeper);
            vm.expectRevert(reason);
            vault.snipe(address(token));
            assertEq(token.balanceOf(address(vault)), 0);
            return;
        }
        vm.prank(keeper);
        vault.snipe(address(token));
        uint256 spent = beforeBalance - _balance(asset);
        uint256 received = token.balanceOf(address(vault));
        assertGt(spent, 0);
        assertGt(received, 0);
        assertLe(spent, budget, "per-purchase spend cap");
        assertLe(received, supply / 50, "two percent supply cap");
        assertEq(spent, received, "local venue one-to-one execution");
        cashOut[asset] += spent;
        SniperVault.Position memory p = vault.positionOf(address(token));
        holdings.push(
            Holding({
                token: token,
                bought: received,
                cost: spent,
                sold: 0,
                withdrawn: 0,
                retired: 0,
                donated: 0,
                proceeds: 0,
                rewards: 0,
                lastCost: spent,
                lastLevel: 0,
                policy: keccak256(abi.encode(p.multiples, p.sellBps)),
                closed: false
            })
        );
    }

    function sell(uint256 seed, uint256 price, bool emergency, bool ownerCaller) public {
        if (holdings.length == 0) return;
        uint256 index = seed % holdings.length;
        Holding storage h = holdings[index];
        SniperVault.Position memory p = vault.positionOf(address(h.token));
        price = bound(price, 1, 150);
        venue.setRate(p.poolId, address(h.token), p.asset, price, 1);
        venue.setRate(vault.imdEthPoolId(), address(0), address(imd), 1000, 1);
        address caller = emergency || ownerCaller ? owner : keeper;
        bytes4 reason;
        if (caller == keeper && vault.keeper() != keeper) {
            reason = SniperVault.Unauthorized.selector;
        } else if (p.remainingAmount == 0) {
            reason = SniperVault.NoPosition.selector;
        } else if (!emergency) {
            uint256 level = p.nextLevel;
            while (level < 4 && p.originalAmount * p.sellBps[level] / 10_000 == 0) ++level;
            if (price < p.multiples[level]) reason = SniperVault.TargetNotReached.selector;
        }
        uint256 beforeTokens = h.token.balanceOf(address(vault));
        uint256 beforeRewards = imd.balanceOf(address(staking));
        if (reason != bytes4(0)) {
            vm.prank(caller);
            vm.expectRevert(reason);
            if (emergency) vault.emergencySell(address(h.token));
            else vault.sell(address(h.token));
            return;
        }
        vm.prank(caller);
        if (emergency) vault.emergencySell(address(h.token));
        else vault.sell(address(h.token));
        uint256 amount = beforeTokens - h.token.balanceOf(address(vault));
        uint256 reward = imd.balanceOf(address(staking)) - beforeRewards;
        assertGt(amount, 0, "successful sale moves tokens");
        // At the fixture's 1:1 entry price every sold unit has one unit of cost basis.
        uint256 profitShare = amount * (price - 1) * vault.stakerShareBps() / 10_000;
        assertEq(reward, p.asset == address(0) ? profitShare * 1000 : profitShare, "profit-only reward share");
        h.sold += amount;
        h.proceeds += amount * price;
        h.rewards += reward;
        cashIn[p.asset] += amount * price;
        cashOut[p.asset] += profitShare;
        ++successfulSales;
        _checkpoint(index);
    }

    function withdraw(uint256 seed, uint256 amount) public {
        uint256 choice = seed % (holdings.length + 2);
        address asset = choice == 0 ? address(0) : choice == 1 ? address(imd) : address(holdings[choice - 2].token);
        uint256 available = _balance(asset);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        if (choice >= 2) _recordWithdrawal(choice - 2, amount);
        vm.prank(owner);
        vault.withdraw(asset, amount);
        if (choice < 2) cashOut[asset] += amount;
        else _checkpoint(choice - 2);
        ++ownerWithdrawals;
    }

    function withdrawAll() public {
        cashOut[address(0)] += address(vault).balance;
        cashOut[address(imd)] += imd.balanceOf(address(vault));
        for (uint256 i; i < holdings.length; ++i) {
            _recordWithdrawal(i, holdings[i].token.balanceOf(address(vault)));
        }
        vm.prank(owner);
        vault.withdrawAll();
        for (uint256 i; i < holdings.length; ++i) {
            _checkpoint(i);
        }
        ++ownerWithdrawals;
    }

    function donatePosition(uint256 seed, uint256 amount) public {
        if (holdings.length == 0) return;
        Holding storage h = holdings[seed % holdings.length];
        uint256 available = h.token.balanceOf(address(venue));
        if (available == 0) return;
        amount = bound(amount, 1, Math.min(available, 100 ether));
        vm.prank(address(venue));
        h.token.transfer(address(vault), amount);
        h.donated += amount;
    }

    function retryPurchase(uint256 seed) public {
        if (holdings.length == 0) return;
        address token = address(holdings[seed % holdings.length].token);
        bytes4 reason = vault.keeper() != keeper
            ? SniperVault.Unauthorized.selector
            : vault.paused() ? SniperVault.VaultPaused.selector : SniperVault.AlreadySniped.selector;
        vm.prank(keeper);
        vm.expectRevert(reason);
        vault.snipe(token);
    }

    function unauthorized(uint256 action, bool keeperCaller) public {
        bytes memory data;
        if (action % 4 == 0) data = abi.encodeCall(vault.withdrawAll, ());
        else if (action % 4 == 1) data = abi.encodeCall(vault.setKeeper, (outsider));
        else if (action % 4 == 2) data = abi.encodeCall(vault.withdraw, (address(imd), 1));
        else data = abi.encodeCall(vault.emergencySell, (address(imd)));
        vm.prank(keeperCaller ? keeper : outsider);
        (bool ok, bytes memory result) = address(vault).call(data);
        assertFalse(ok, "unauthorized operation succeeded");
        assertEq(result, abi.encodeWithSelector(SniperVault.Unauthorized.selector));
    }

    function _recordWithdrawal(uint256 index, uint256 amount) private {
        Holding storage h = holdings[index];
        h.withdrawn += amount;
        h.retired += Math.min(amount, vault.positionOf(address(h.token)).remainingAmount);
    }

    function _checkpoint(uint256 index) private {
        Holding storage h = holdings[index];
        SniperVault.Position memory p = vault.positionOf(address(h.token));
        assertLe(p.remainingCost, h.lastCost, "cost never grows after purchase");
        assertGe(p.nextLevel, h.lastLevel, "ladder never reopens");
        h.lastCost = p.remainingCost;
        h.lastLevel = p.nextLevel;
        if (p.remainingAmount == 0) h.closed = true;
    }

    function _balance(address asset) private view returns (uint256) {
        return asset == address(0) ? address(vault).balance : MockERC20(asset).balanceOf(address(vault));
    }

    function assertAccounting() public view {
        assertEq(address(vault).balance + cashOut[address(0)], cashIn[address(0)], "ETH flow conservation");
        assertEq(imd.balanceOf(address(vault)) + cashOut[address(imd)], cashIn[address(imd)], "IMD flow conservation");
        assertEq(vault.snipedTokenCount(), holdings.length);
        uint256 rewards;
        for (uint256 i; i < holdings.length; ++i) {
            Holding storage h = holdings[i];
            SniperVault.Position memory p = vault.positionOf(address(h.token));
            assertEq(vault.snipedTokens(i), address(h.token), "unique purchase index");
            assertEq(p.originalAmount, h.bought);
            assertEq(p.entryCost, h.cost);
            assertEq(p.remainingAmount + h.sold + h.retired, h.bought, "position conservation");
            assertEq(h.token.balanceOf(address(vault)) + h.sold + h.withdrawn, h.bought + h.donated, "token flows");
            assertEq(h.token.balanceOf(owner), h.withdrawn, "withdrawals go only to owner");
            assertEq(p.remainingCost, p.remainingAmount, "one-to-one entry cost conservation");
            assertEq(p.proceeds, h.proceeds);
            assertEq(p.rewardsImd, h.rewards);
            assertEq(keccak256(abi.encode(p.multiples, p.sellBps)), h.policy, "purchase policy remains fixed");
            assertLe(p.nextLevel, 5);
            if (h.closed) assertEq(p.remainingAmount, 0, "closed position reopened");
            assertEq(h.token.allowance(address(vault), address(venue)), 0);
            assertEq(h.token.balanceOf(keeper), 0);
            assertEq(h.token.balanceOf(outsider), 0);
            rewards += h.rewards;
        }
        assertEq(staking.totalRewardsFunded(), rewards, "all sale rewards reach staking");
        assertEq(staking.rewardLiability(), rewards);
        assertEq(imd.balanceOf(address(staking)), rewards);
        assertEq(imd.allowance(address(vault), address(venue)), 0);
        assertEq(imd.allowance(address(vault), address(staking)), 0);
        assertEq(imd.balanceOf(keeper), 0);
        assertEq(imd.balanceOf(outsider), 0);
        assertEq(keeper.balance, 0);
        assertEq(outsider.balance, 0);
    }
}

contract SniperVaultInvariantTest is BaseTest {
    VaultSequenceHandler private handler;

    function setUp() public override {
        super.setUp();
        imd.mint(OWNER, 1_000_000 ether);
        vm.deal(OWNER, 1_000_000 ether);
        handler = new VaultSequenceHandler(vault, KEEPER, EVE);
        handler.snipe(1_000_000 ether, false);
        handler.snipe(1_000_000 ether, true);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.configure.selector;
        selectors[2] = handler.snipe.selector;
        selectors[3] = handler.sell.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.withdrawAll.selector;
        selectors[6] = handler.donatePosition.selector;
        selectors[7] = handler.retryPurchase.selector;
        selectors[8] = handler.unauthorized.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_assetFlowsPositionsAndKeeperIsolation() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        vm.prank(OWNER);
        vault.pause();
        handler.withdrawAll();
        handler.assertAccounting();
        assertEq(address(vault).balance, 0);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_handlerExercisesBothAssetsAndClosedPositionDonations() public {
        handler.sell(0, 5, false, false);
        handler.sell(1, 10, false, true);
        handler.withdraw(2, 1);
        handler.sell(0, 1, true, true);
        handler.donatePosition(0, 10);
        handler.retryPurchase(0);
        handler.configure(100, 1000, 5000, true, true);
        handler.unauthorized(0, true);
        handler.withdrawAll();
        handler.assertAccounting();
        assertEq(handler.successfulSales(), 3);
        assertGt(handler.ownerWithdrawals(), 0);
    }
}
