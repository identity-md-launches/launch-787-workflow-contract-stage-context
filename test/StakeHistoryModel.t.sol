// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";

/// @dev The reference model adds balance * elapsed to each affected day on every interval.
/// It does not use checkpoints, prefix integrals, or binary search like the implementation.
contract StakeHistoryModelTest is BaseTest {
    function testFuzz_historyMatchesIndependentIntervalModel(uint256 seed) public {
        uint256[2] memory balances;
        uint256[2][9] memory weights;
        uint256 timestamp = START;
        for (uint256 step; step < 24; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 elapsed = seed % 8 hours;
            uint256 next = timestamp + elapsed;
            _addInterval(weights, balances, timestamp, next);
            vm.warp(next);
            timestamp = next;
            uint256 who = (seed >> 32) % 2;
            address account = who == 0 ? ALICE : BOB;
            uint256 amount = ((seed >> 64) % 100 + 1) * 1 ether;
            if ((seed >> 128) % 2 == 0 && balances[who] > 0) {
                amount = amount < balances[who] ? amount : balances[who];
                vm.prank(account);
                staking.unstake(amount);
                balances[who] -= amount;
            } else {
                _stake(account, amount);
                balances[who] += amount;
            }
            assertEq(staking.totalStaked(), balances[0] + balances[1]);
            assertEq(company.balanceOf(address(staking)), balances[0] + balances[1]);
        }
        uint256 end = START + 8 days;
        _addInterval(weights, balances, timestamp, end);
        vm.warp(end);
        for (uint256 day; day < 8; ++day) {
            (uint256 aliceWeight, uint256 totalWeight) = staking.stakeSeconds(ALICE, BATCH + day);
            (uint256 bobWeight,) = staking.stakeSeconds(BOB, BATCH + day);
            assertEq(aliceWeight, weights[day][0]);
            assertEq(bobWeight, weights[day][1]);
            assertEq(totalWeight, weights[day][0] + weights[day][1]);
        }
    }

    function _addInterval(uint256[2][9] memory weights, uint256[2] memory balances, uint256 from, uint256 to)
        private
        pure
    {
        while (from < to) {
            uint256 day = (from - START) / 1 days;
            uint256 boundary = START + (day + 1) * 1 days;
            uint256 end = to < boundary ? to : boundary;
            weights[day][0] += balances[0] * (end - from);
            weights[day][1] += balances[1] * (end - from);
            from = end;
        }
    }
}
