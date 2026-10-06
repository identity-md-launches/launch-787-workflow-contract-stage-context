// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Trading} from "./lib/Trading.sol";
import {StakeHistory} from "./lib/StakeHistory.sol";

/// @notice COMPANY staking with UTC-day stake-seconds, seven-day claims and expired-reward buybacks.
/// @dev No owner, rescue, pause, upgrade or privileged payout function exists here.
contract CompanyStaking is Trading {
    using SafeERC20 for IERC20;
    using StakeHistory for StakeHistory.Checkpoint[];

    uint256 public constant DAY = 1 days;
    uint256 public constant CLAIM_DAYS = 7;
    uint256 public constant BURN_SLIPPAGE_BPS = 1000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable company;
    uint256 public immutable firstBatch;
    uint256 public totalStaked;
    uint256 public rewardLiability;
    uint256 public totalRewardsFunded;
    uint256 public totalRewardsPaid;
    uint256 public totalImdBurned;
    uint256 public totalCompanyBurned;

    struct Batch {
        uint256 funded;
        uint256 claimed;
        bool burned;
    }

    mapping(address => uint256) public balanceOf;
    mapping(uint256 => Batch) public batches;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(address => StakeHistory.Checkpoint[]) private histories;
    StakeHistory.Checkpoint[] private totalHistory;

    error InsufficientStake();
    error UnsupportedToken();
    error BatchNotClaimable();
    error BatchNotExpired();
    error BatchAlreadyBurned();
    error UnknownBatch();
    error InvalidNativeSender();

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardsFunded(uint256 indexed batchId, address indexed funder, uint256 amount);
    event RewardClaimed(uint256 indexed batchId, address indexed account, uint256 amount);
    event ExpiredBurned(uint256 indexed batchId, uint256 imdSpent, uint256 companySentToDead);

    constructor(
        address company_,
        address imd_,
        address registry_,
        address launchFactory_,
        address venue_,
        bytes32 imdEthPoolId_,
        uint256 chainId_
    ) Trading(imd_, registry_, launchFactory_, venue_, imdEthPoolId_, chainId_) {
        if (company_ == address(0) || company_ == imd_) revert InvalidConfiguration();
        company = company_;
        firstBatch = block.timestamp / DAY;
    }

    receive() external payable {
        if (msg.sender != address(venue)) revert InvalidNativeSender();
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        balanceOf[msg.sender] += amount;
        totalStaked += amount;
        histories[msg.sender].write(balanceOf[msg.sender]);
        totalHistory.write(totalStaked);
        uint256 beforeBalance = IERC20(company).balanceOf(address(this));
        IERC20(company).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(company).balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[msg.sender]) revert InsufficientStake();
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        histories[msg.sender].write(balanceOf[msg.sender]);
        totalHistory.write(totalStaked);
        IERC20(company).safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Pull IMD into today's batch. Permissionless funding removes any privileged reward authority
    /// and the need to initialize a vault address after factory deployment. Donations cannot dilute shares.
    function notifyReward(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 id = block.timestamp / DAY;
        batches[id].funded += amount;
        rewardLiability += amount;
        totalRewardsFunded += amount;
        uint256 beforeBalance = IERC20(imd).balanceOf(address(this));
        IERC20(imd).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(imd).balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
        emit RewardsFunded(id, msg.sender, amount);
    }

    /// @notice One batch is [id * DAY, (id + 1) * DAY); its claim window starts on completion.
    function batchWindow(uint256 batchId) public pure returns (uint256 closesAt, uint256 expiresAt) {
        closesAt = (batchId + 1) * DAY;
        expiresAt = closesAt + CLAIM_DAYS * DAY;
    }

    function stakeSeconds(address account, uint256 batchId) public view returns (uint256 personal, uint256 aggregate) {
        if (batchId < firstBatch || batchId >= block.timestamp / DAY) return (0, 0);
        uint256 start = batchId * DAY;
        uint256 end = start + DAY;
        personal = histories[account].between(start, end);
        aggregate = totalHistory.between(start, end);
    }

    function claimable(address account, uint256 batchId) public view returns (uint256) {
        uint256 today = block.timestamp / DAY;
        if (batchId < firstBatch || batchId >= today || today - batchId > CLAIM_DAYS) return 0;
        if (claimed[batchId][account] || batches[batchId].burned) return 0;
        (uint256 personal, uint256 aggregate) = stakeSeconds(account, batchId);
        return aggregate == 0 ? 0 : Math.mulDiv(batches[batchId].funded, personal, aggregate);
    }

    function claim(uint256 batchId) external nonReentrant returns (uint256 amount) {
        uint256 today = block.timestamp / DAY;
        if (batchId < firstBatch || batchId >= today || today - batchId > CLAIM_DAYS || claimed[batchId][msg.sender]) {
            revert BatchNotClaimable();
        }
        amount = _claim(msg.sender, batchId);
        if (amount != 0) IERC20(imd).safeTransfer(msg.sender, amount);
    }

    /// @notice At most seven batch queries; unaffected by the number of inactive days or stakers.
    function claimAll() external nonReentrant returns (uint256 amount) {
        uint256 today = block.timestamp / DAY;
        uint256 start = today > CLAIM_DAYS ? today - CLAIM_DAYS : 0;
        start = Math.max(start, firstBatch);
        for (uint256 id = start; id < today; ++id) {
            amount += _claim(msg.sender, id);
        }
        if (amount != 0) IERC20(imd).safeTransfer(msg.sender, amount);
    }

    function _claim(address account, uint256 batchId) private returns (uint256 amount) {
        if (claimed[batchId][account]) return 0;
        amount = claimable(account, batchId);
        claimed[batchId][account] = true;
        batches[batchId].claimed += amount;
        rewardLiability -= amount;
        totalRewardsPaid += amount;
        if (amount != 0) emit RewardClaimed(batchId, account, amount);
    }

    /// @notice Spend only this expired batch's unclaimed IMD; no caller-selected route or beneficiary.
    function burnExpired(uint256 batchId) external nonReentrant returns (uint256 burnedCompany) {
        Batch storage batch = batches[batchId];
        if (batch.funded == 0) revert UnknownBatch();
        if (batch.burned) revert BatchAlreadyBurned();
        (, uint256 expiresAt) = batchWindow(batchId);
        if (block.timestamp < expiresAt) revert BatchNotExpired();
        uint256 amount = batch.funded - batch.claimed;
        batch.burned = true;
        rewardLiability -= amount;
        totalImdBurned += amount;
        if (amount != 0) {
            (address pairedAsset, bytes32 pool) = _launch(company);
            uint256 companyBefore = IERC20(company).balanceOf(address(this));
            if (pairedAsset == imd) {
                burnedCompany = _quotedSwap(pool, imd, company, amount, BURN_SLIPPAGE_BPS);
            } else {
                uint256 ethAmount = _quotedSwap(imdEthPoolId, imd, address(0), amount, BURN_SLIPPAGE_BPS);
                burnedCompany = _quotedSwap(pool, address(0), company, ethAmount, BURN_SLIPPAGE_BPS);
            }
            IERC20(company).safeTransfer(DEAD, burnedCompany);
            // Principal and unsolicited COMPANY donations stay exactly where they were.
            if (IERC20(company).balanceOf(address(this)) != companyBefore) revert SwapAccounting();
            totalCompanyBurned += burnedCompany;
        }
        emit ExpiredBurned(batchId, amount, burnedCompany);
    }
}
