// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SniperVault} from "../src/SniperVault.sol";
import {CompanyStaking} from "../src/CompanyStaking.sol";
import {Trading} from "../src/lib/Trading.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRegistry} from "./mocks/MockRegistry.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

abstract contract BaseTest is Test {
    uint256 internal constant START = 20_000 days;
    uint256 internal constant BATCH = 20_000;
    bytes32 internal constant IMD_POOL = keccak256("IMD/ETH");
    bytes32 internal constant COMPANY_POOL = keccak256("COMPANY/IMD");
    bytes32 internal constant SNIPE_POOL = keccak256("SNIPE/IMD");
    bytes32 internal constant NATIVE_POOL = keccak256("SNIPE/ETH");
    address internal constant FACTORY = address(0xFAC7);
    address internal constant OWNER = address(0xA11CE);
    address internal constant KEEPER = address(0xB07);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0B);
    address internal constant EVE = address(0xE1E);

    LaunchToken internal company;
    MockERC20 internal imd;
    MockERC20 internal target;
    MockERC20 internal nativeTarget;
    MockRegistry internal registry;
    MockVenue internal venue;
    CompanyStaking internal staking;
    SniperVault internal vault;

    function setUp() public virtual {
        vm.warp(START);
        company = new LaunchToken();
        imd = new MockERC20("IMD", "IMD", 18);
        target = new MockERC20("Launch", "LAUNCH", 18);
        nativeTarget = new MockERC20("Native launch", "NATIVE", 18);
        registry = new MockRegistry();
        venue = new MockVenue();
        staking = new CompanyStaking(
            address(company), address(imd), address(registry), FACTORY, address(venue), IMD_POOL, block.chainid
        );
        vault = new SniperVault(OWNER, address(staking));
        registry.setLaunch(address(company), FACTORY, address(imd), COMPANY_POOL);
        registry.setLaunch(address(target), FACTORY, address(imd), SNIPE_POOL);
        registry.setLaunch(address(nativeTarget), FACTORY, address(0), NATIVE_POOL);
        company.transfer(ALICE, 100_000 ether);
        company.transfer(BOB, 100_000 ether);
        company.transfer(address(venue), 1_000_000 ether);
        imd.mint(OWNER, 1_000_000 ether);
        imd.mint(address(this), 1_000_000 ether);
        imd.mint(address(venue), 1_000_000_000 ether);
        target.mint(address(venue), 1_000_000_000 ether);
        nativeTarget.mint(address(venue), 1_000_000_000 ether);
        vm.deal(OWNER, 1_000 ether);
        vm.deal(address(venue), 1_000_000 ether);
        _refreshRates();
        vm.startPrank(OWNER);
        imd.approve(address(vault), 1000 ether);
        vault.depositIMD(1000 ether);
        vault.depositETH{value: 10 ether}();
        vault.setKeeper(KEEPER);
        vm.stopPrank();
        vm.prank(ALICE);
        company.approve(address(staking), type(uint256).max);
        vm.prank(BOB);
        company.approve(address(staking), type(uint256).max);
        imd.approve(address(staking), type(uint256).max);
    }

    function _refreshRates() internal {
        venue.setRate(IMD_POOL, address(0), address(imd), 1000, 1);
        venue.setRate(IMD_POOL, address(imd), address(0), 1, 1000);
        venue.setRate(COMPANY_POOL, address(imd), address(company), 2, 1);
        venue.setRate(COMPANY_POOL, address(0), address(company), 2000, 1);
        venue.setRate(SNIPE_POOL, address(imd), address(target), 100, 1);
        venue.setRate(SNIPE_POOL, address(target), address(imd), 1, 100);
        venue.setRate(NATIVE_POOL, address(0), address(nativeTarget), 10_000, 1);
        venue.setRate(NATIVE_POOL, address(nativeTarget), address(0), 1, 10_000);
    }

    function _buy(address token) internal returns (SniperVault.Position memory position) {
        vm.prank(OWNER);
        vault.setSlippageBps(0);
        vm.prank(KEEPER);
        vault.snipe(token);
        position = vault.positionOf(token);
    }

    function _stake(address account, uint256 amount) internal {
        vm.prank(account);
        staking.stake(amount);
    }

    function _price(uint256 multiple) internal {
        venue.setRate(SNIPE_POOL, address(target), address(imd), multiple, 100);
        venue.setRate(NATIVE_POOL, address(nativeTarget), address(0), multiple, 10_000);
    }
}
