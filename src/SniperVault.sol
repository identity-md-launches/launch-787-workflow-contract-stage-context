// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Trading} from "./lib/Trading.sol";
import {CompanyStaking} from "./CompanyStaking.sol";

/// @notice Owner-custodied trading treasury with tightly scoped keeper execution.
contract SniperVault is Trading {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SUPPLY_BPS = 200;
    address public immutable owner;
    CompanyStaking public immutable staking;
    address public keeper;
    bool public paused;
    uint256 public maxSpendBps = 100;
    uint256 public slippageBps = 1000;
    uint256 public stakerShareBps = 3000;
    uint32[5] public ladderMultiples = [5, 10, 25, 50, 100];
    uint16[5] public ladderSellBps = [2000, 2000, 2000, 2000, 2000];

    struct Position {
        address asset;
        bytes32 poolId;
        uint256 originalAmount;
        uint256 remainingAmount;
        uint256 entryCost;
        uint256 remainingCost;
        uint256 entryPrice; // Asset minor units per token minor unit, scaled by 1e18; display only.
        uint256 proceeds;
        uint256 rewardsImd;
        uint8 nextLevel;
        uint32[5] multiples;
        uint16[5] sellBps;
    }

    mapping(address => Position) private positions;
    address[] public snipedTokens;

    error Unauthorized();
    error VaultPaused();
    error AlreadySniped();
    error NoPosition();
    error TargetNotReached();
    error InvalidParameters();
    error UnsupportedToken();

    event Deposited(address indexed asset, uint256 amount);
    event Withdrawn(address indexed asset, uint256 amount);
    event KeeperChanged(address indexed keeper);
    event PauseChanged(bool paused);
    event MaxSpendChanged(uint256 bps);
    event SlippageChanged(uint256 bps);
    event StakerShareChanged(uint256 bps);
    event LadderChanged(uint32[5] multiples, uint16[5] sellBps);
    event Sniped(address indexed token, address indexed asset, uint256 amount, uint256 cost, uint256 entryPrice);
    event Sold(
        address indexed token,
        address indexed asset,
        uint8 level,
        uint256 amount,
        uint256 proceeds,
        uint256 costBasis,
        uint256 profit,
        uint256 rewardsImd,
        bool emergency
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address owner_, address staking_)
        Trading(
            CompanyStaking(payable(staking_)).imd(),
            address(CompanyStaking(payable(staking_)).registry()),
            CompanyStaking(payable(staking_)).launchFactory(),
            address(CompanyStaking(payable(staking_)).venue()),
            CompanyStaking(payable(staking_)).imdEthPoolId(),
            CompanyStaking(payable(staking_)).expectedChainId()
        )
    {
        if (owner_ == address(0)) revert InvalidConfiguration();
        owner = owner_;
        staking = CompanyStaking(payable(staking_));
    }

    receive() external payable {
        if (msg.sender != owner && msg.sender != address(venue)) revert Unauthorized();
        if (msg.sender == owner) emit Deposited(address(0), msg.value);
    }

    function depositIMD(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = _balance(imd);
        IERC20(imd).safeTransferFrom(msg.sender, address(this), amount);
        if (_balance(imd) - beforeBalance != amount) revert UnsupportedToken();
        emit Deposited(imd, amount);
    }

    function depositETH() external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        emit Deposited(address(0), msg.value);
    }

    function withdraw(address asset, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _withdraw(asset, amount);
    }

    /// @notice Withdraws both funding assets and every token ever bought, including while paused.
    /// Use withdraw(asset, amount) for bounded work if the token list is too large or one token reverts.
    function withdrawAll() external onlyOwner nonReentrant {
        uint256 amount = _balance(address(0));
        if (amount != 0) _withdraw(address(0), amount);
        amount = _balance(imd);
        if (amount != 0) _withdraw(imd, amount);
        for (uint256 i; i < snipedTokens.length; ++i) {
            address token = snipedTokens[i];
            amount = _balance(token);
            if (amount != 0) _withdraw(token, amount);
        }
    }

    function _withdraw(address asset, uint256 amount) private {
        Position storage position = positions[asset];
        uint256 retired = Math.min(amount, position.remainingAmount);
        if (retired != 0) _removeCost(position, retired);
        _send(asset, owner, amount);
        emit Withdrawn(asset, amount);
    }

    function pause() external onlyOwner nonReentrant {
        paused = true;
        emit PauseChanged(true);
    }

    function unpause() external onlyOwner nonReentrant {
        paused = false;
        emit PauseChanged(false);
    }

    /// @notice Zero disables the keeper. There is no keeper withdrawal or gas-reimbursement path.
    function setKeeper(address keeper_) external onlyOwner nonReentrant {
        keeper = keeper_;
        emit KeeperChanged(keeper_);
    }

    function setMaxSpendBps(uint256 bps) external onlyOwner nonReentrant {
        if (bps == 0 || bps > BPS) revert InvalidParameters();
        maxSpendBps = bps;
        emit MaxSpendChanged(bps);
    }

    function setSlippageBps(uint256 bps) external onlyOwner nonReentrant {
        if (bps >= BPS) revert InvalidParameters();
        slippageBps = bps;
        emit SlippageChanged(bps);
    }

    function setStakerShareBps(uint256 bps) external onlyOwner nonReentrant {
        if (bps > 5000) revert InvalidParameters();
        stakerShareBps = bps;
        emit StakerShareChanged(bps);
    }

    /// @notice Changes apply only to future positions. Thresholds are integer price multiples.
    function setLadder(uint32[5] calldata multiples, uint16[5] calldata sellBps) external onlyOwner nonReentrant {
        uint256 sum;
        uint256 previous = 1;
        for (uint256 i; i < 5; ++i) {
            if (multiples[i] <= previous || sellBps[i] == 0) revert InvalidParameters();
            previous = multiples[i];
            sum += sellBps[i];
        }
        if (sum != BPS) revert InvalidParameters();
        ladderMultiples = multiples;
        ladderSellBps = sellBps;
        emit LadderChanged(multiples, sellBps);
    }

    function positionOf(address token) external view returns (Position memory) {
        return positions[token];
    }

    function snipedTokenCount() external view returns (uint256) {
        return snipedTokens.length;
    }

    function snipe(address token) external nonReentrant {
        if (msg.sender != keeper) revert Unauthorized();
        if (paused) revert VaultPaused();
        Position storage position = positions[token];
        if (position.originalAmount != 0) revert AlreadySniped();
        (address asset, bytes32 pool) = _launch(token);
        uint256 budget = Math.mulDiv(_balance(asset), maxSpendBps, BPS);
        if (budget == 0) revert ZeroAmount();
        uint256 cap = Math.mulDiv(IERC20(token).totalSupply(), MAX_SUPPLY_BPS, BPS);
        uint256 amount = Math.min(cap, Math.mulDiv(_quote(pool, asset, token, budget, false), BPS, BPS + slippageBps));
        if (amount == 0) revert ZeroAmount();
        uint256 maxInput = Math.min(
            budget, Math.mulDiv(_quote(pool, asset, token, amount, true), BPS + slippageBps, BPS, Math.Rounding.Ceil)
        );
        // Mark origin and snapshot the policy before interacting. Any failure rolls back the mark.
        position.asset = asset;
        position.poolId = pool;
        position.originalAmount = amount;
        position.remainingAmount = amount;
        position.multiples = ladderMultiples;
        position.sellBps = ladderSellBps;
        snipedTokens.push(token);
        uint256 spent = _swapOutput(pool, asset, token, amount, maxInput);
        position.entryCost = spent;
        position.remainingCost = spent;
        position.entryPrice = Math.mulDiv(spent, 1e18, amount);
        emit Sniped(token, asset, amount, spent, position.entryPrice);
    }

    /// @notice Executes the next nonzero tranche, once. Call repeatedly if price crosses several levels.
    function sell(address token) external nonReentrant {
        if (msg.sender != keeper && msg.sender != owner) revert Unauthorized();
        Position storage position = positions[token];
        if (position.remainingAmount == 0) revert NoPosition();
        uint256 amount;
        uint8 level = position.nextLevel;
        while (level < 5) {
            amount = level == 4
                ? position.remainingAmount
                : Math.min(position.remainingAmount, Math.mulDiv(position.originalAmount, position.sellBps[level], BPS));
            if (amount != 0) break;
            ++level;
        }
        if (level == 5) revert NoPosition();
        uint256 target = Math.mulDiv(amount, position.entryCost, position.originalAmount, Math.Rounding.Ceil)
            * position.multiples[level];
        uint256 quoted = _quote(position.poolId, token, position.asset, amount, false);
        if (quoted < target) revert TargetNotReached();
        position.nextLevel = level + 1;
        _sell(token, position, amount, Math.max(target, _minimum(quoted, slippageBps)), level, false);
    }

    function emergencySell(address token) external onlyOwner nonReentrant {
        Position storage position = positions[token];
        uint256 amount = position.remainingAmount;
        if (amount == 0) revert NoPosition();
        uint256 minimum = _minimum(_quote(position.poolId, token, position.asset, amount, false), slippageBps);
        position.nextLevel = 5;
        _sell(token, position, amount, minimum, 5, true);
    }

    function _sell(
        address token,
        Position storage position,
        uint256 amount,
        uint256 minimum,
        uint8 level,
        bool emergency
    ) private {
        uint256 cost = _removeCost(position, amount);
        uint256 proceeds = _swapInput(position.poolId, token, position.asset, amount, minimum);
        uint256 profit = proceeds > cost ? proceeds - cost : 0;
        uint256 share = Math.mulDiv(profit, stakerShareBps, BPS);
        uint256 reward;
        if (share != 0) {
            reward = position.asset == imd ? share : _quotedSwap(imdEthPoolId, address(0), imd, share, slippageBps);
            IERC20(imd).forceApprove(address(staking), reward);
            staking.notifyReward(reward);
            IERC20(imd).forceApprove(address(staking), 0);
        }
        position.proceeds += proceeds;
        position.rewardsImd += reward;
        emit Sold(token, position.asset, level, amount, proceeds, cost, profit, reward, emergency);
    }

    function _removeCost(Position storage position, uint256 amount) private returns (uint256 cost) {
        cost = amount == position.remainingAmount
            ? position.remainingCost
            : Math.mulDiv(position.remainingCost, amount, position.remainingAmount);
        position.remainingAmount -= amount;
        position.remainingCost -= cost;
    }
}
