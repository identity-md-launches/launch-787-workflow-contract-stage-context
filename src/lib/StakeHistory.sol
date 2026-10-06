// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Prefix integrals allow O(log n) historical queries and O(1) balance changes,
/// even when an account has been idle for years. Same-timestamp changes replace one checkpoint.
library StakeHistory {
    struct Checkpoint {
        uint256 timestamp;
        uint256 balance;
        uint256 integral;
    }

    function write(Checkpoint[] storage self, uint256 balance) internal {
        uint256 length = self.length;
        uint256 integral;
        if (length != 0) {
            Checkpoint storage last = self[length - 1];
            if (last.timestamp == block.timestamp) {
                last.balance = balance;
                return;
            }
            integral = last.integral + last.balance * (block.timestamp - last.timestamp);
        }
        self.push(Checkpoint(block.timestamp, balance, integral));
    }

    function at(Checkpoint[] storage self, uint256 timestamp) internal view returns (uint256) {
        uint256 low;
        uint256 high = self.length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (self[mid].timestamp > timestamp) high = mid;
            else low = mid + 1;
        }
        if (low == 0) return 0;
        Checkpoint storage checkpoint = self[low - 1];
        return checkpoint.integral + checkpoint.balance * (timestamp - checkpoint.timestamp);
    }

    function between(Checkpoint[] storage self, uint256 start, uint256 end) internal view returns (uint256) {
        return at(self, end) - at(self, start);
    }
}
