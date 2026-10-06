// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Deliberately configurable adversarial token; never a production deployment artifact.
contract MockERC20 is ERC20 {
    uint8 private immutable tokenDecimals;
    uint256 public feeBps;
    bool public transfersFail;
    address public blockedRecipient;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;
    bool private calling;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint256 fee, bool fail) external {
        feeBps = fee;
        transfersFail = fail;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!transfersFail, "token transfer failed");
        require(blockedRecipient == address(0) || to != blockedRecipient, "recipient blocked");
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = amount * feeBps / 10_000;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
        if (callbackTarget != address(0) && !calling) {
            calling = true;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
            calling = false;
        }
    }
}
