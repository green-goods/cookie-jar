// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IGardenHats {
    /// @notice Report current, active Hat membership including eligibility and standing.
    function isWearerOfHat(address account, uint256 hat) external view returns (bool);
}

/// @title GardenCookieJar
/// @notice A single-asset payout jar administered by a garden's Hats.
/// @dev Non-upgradeable. Hat membership is checked on every call; no caller forwarding is supported.
contract GardenCookieJar is Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Policy {
        uint256 maxClaimCeiling;
        uint256 minCooldown;
        uint256 dailyBudget;
        address recoveryRecipient;
    }

    struct Config {
        address garden;
        address asset;
        address hats;
        uint256 gardenerHat;
        uint256 stewardHat;
        uint256 ownerHat;
        Policy policy;
        uint256 maxWithdrawal;
        uint256 withdrawalInterval;
    }

    uint256 public constant VERSION = 1;
    bytes32 public constant FAMILY = keccak256("GREEN_GOODS_GARDEN_COOKIE_JAR");
    uint256 public constant POLICY_DELAY = 48 hours;
    uint256 public constant MIN_DEPOSIT = 0;
    uint256 public constant FEE_PERCENTAGE_ON_DEPOSIT = 0;
    bool public constant EMERGENCY_WITHDRAWAL_ENABLED = true;
    uint256 public constant MAX_PURPOSE_BYTES = 512;

    address public immutable GARDEN;
    address public immutable CURRENCY;
    address public immutable HATS;
    uint256 public immutable GARDENER_HAT;
    uint256 public immutable STEWARD_HAT;
    uint256 public immutable OWNER_HAT;
    address public immutable FACTORY;

    Policy public policy;
    Policy public pendingPolicy;
    address public pendingPolicyProposer;
    uint256 public pendingPolicyAt;
    bytes32 public pendingPolicyHash;
    uint256 public maxWithdrawal;
    uint256 public withdrawalInterval;
    uint256 public currencyHeldByJar;
    mapping(address => uint256) public lastWithdrawalTime;
    mapping(address => uint256) public totalWithdrawn;
    uint256 public budgetDay;
    uint256 public claimedToday;

    event Deposited(address indexed funder, address indexed asset, uint256 amount);
    event Claimed(address indexed gardener, address indexed asset, uint256 amount, bytes32 purposeHash);
    event OperationalLimitsChanged(address indexed actor, uint256 maxWithdrawal, uint256 withdrawalInterval);
    event PolicyProposed(address indexed proposer, bytes32 indexed policyHash, uint256 readyAt);
    event PolicyCancelled(address indexed actor, bytes32 indexed policyHash);
    event PolicyApplied(address indexed actor, bytes32 indexed policyHash);
    event EmergencyWithdrawal(address indexed actor, address indexed recipient, address indexed asset, uint256 amount);
    event SurplusRecovered(address indexed actor, address indexed recipient, address indexed asset, uint256 amount);

    error NotOwner();
    error NotOperator();
    error NotGardener();
    error InvalidConfiguration();
    error InvalidPolicy();
    error InvalidOperationalLimits();
    error InvalidAmount();
    error InvalidPurpose();
    error ClaimExceedsLimit();
    error ClaimTooSoon(uint256 readyAt);
    error DailyBudgetExceeded();
    error InsufficientCredit();
    error UnsupportedTokenTransfer();
    error InsolventJar();
    error NoPendingPolicy();
    error PolicyNotReady(uint256 readyAt);
    error ProposerNoLongerOwner();
    error UnexpectedPolicy();
    error InsufficientSurplus();
    error NativeTransferFailed();

    modifier onlyOwner() {
        if (!_isOwner(msg.sender)) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (!_isOwner(msg.sender) && !_isSteward(msg.sender)) revert NotOperator();
        _;
    }

    constructor(Config memory config) {
        if (
            config.garden == address(0) || config.asset.code.length == 0 || config.hats.code.length == 0 ||
            config.gardenerHat == 0 || config.stewardHat == 0 || config.ownerHat == 0
        ) revert InvalidConfiguration();
        GARDEN = config.garden;
        CURRENCY = config.asset;
        HATS = config.hats;
        GARDENER_HAT = config.gardenerHat;
        STEWARD_HAT = config.stewardHat;
        OWNER_HAT = config.ownerHat;
        FACTORY = msg.sender;
        _validatePolicy(config.policy);
        policy = config.policy;
        _setOperationalLimits(config.maxWithdrawal, config.withdrawalInterval);
    }

    /// @notice Credit an exact deposit of the configured asset, with no fee or native value.
    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert InvalidAmount();
        IERC20 token = IERC20(CURRENCY);
        uint256 beforeBalance = token.balanceOf(address(this));
        if (beforeBalance < currencyHeldByJar) revert InsolventJar();
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnsupportedTokenTransfer();
        currencyHeldByJar += amount;
        emit Deposited(msg.sender, CURRENCY, amount);
    }

    /// @notice Claim to the current gardener Hat wearer's own address.
    function withdraw(uint256 amount, string calldata purpose) external whenNotPaused nonReentrant {
        if (!IGardenHats(HATS).isWearerOfHat(msg.sender, GARDENER_HAT)) revert NotGardener();
        if (amount == 0) revert InvalidAmount();
        if (amount > maxWithdrawal) revert ClaimExceedsLimit();
        if (bytes(purpose).length > MAX_PURPOSE_BYTES) revert InvalidPurpose();
        uint256 last = lastWithdrawalTime[msg.sender];
        // totalWithdrawn also distinguishes a real claim made at timestamp zero.
        if (totalWithdrawn[msg.sender] != 0 && block.timestamp < last + withdrawalInterval) {
            revert ClaimTooSoon(last + withdrawalInterval);
        }
        if (amount > currencyHeldByJar) revert InsufficientCredit();
        _requireSolvent();
        uint256 day = block.timestamp / 1 days;
        uint256 spent = day == budgetDay ? claimedToday : 0;
        uint256 nextSpent = spent + amount;
        if (policy.dailyBudget != 0 && nextSpent > policy.dailyBudget) revert DailyBudgetExceeded();
        budgetDay = day;
        claimedToday = nextSpent;
        lastWithdrawalTime[msg.sender] = block.timestamp;
        totalWithdrawn[msg.sender] += amount;
        currencyHeldByJar -= amount;
        _transferExact(CURRENCY, msg.sender, amount);
        emit Claimed(msg.sender, CURRENCY, amount, keccak256(bytes(purpose)));
    }

    /// @notice Stewards and owners may operate only inside the owner's active policy bounds.
    function setOperationalLimits(uint256 claimLimit, uint256 cooldown) external onlyOperator nonReentrant {
        _setOperationalLimits(claimLimit, cooldown);
    }

    /// @notice Stop deposits and claims immediately without changing balances or claim clocks.
    function pause() external onlyOperator nonReentrant {
        _pause();
    }

    /// @notice Only a current owner may resume deposits and claims.
    function unpause() external onlyOwner nonReentrant {
        _requireSolvent();
        _unpause();
    }

    /// @notice Schedule policy or recovery-recipient changes after the fixed notice period.
    function proposePolicy(Policy calldata nextPolicy) external onlyOwner nonReentrant {
        _validatePolicy(nextPolicy);
        pendingPolicy = nextPolicy;
        pendingPolicyProposer = msg.sender;
        pendingPolicyAt = block.timestamp + POLICY_DELAY;
        pendingPolicyHash = keccak256(abi.encode(nextPolicy));
        emit PolicyProposed(msg.sender, pendingPolicyHash, pendingPolicyAt);
    }

    /// @notice A current owner can cancel a proposal, including one made by a revoked owner.
    function cancelPolicy() external onlyOwner nonReentrant {
        if (pendingPolicyProposer == address(0)) revert NoPendingPolicy();
        bytes32 policyHash = pendingPolicyHash;
        _clearPendingPolicy();
        emit PolicyCancelled(msg.sender, policyHash);
    }

    /// @notice Apply a mature proposal only while its proposer still wears the owner Hat.
    /// @param expectedPolicyHash The hash of the exact policy the executor reviewed.
    function executePolicy(bytes32 expectedPolicyHash) external onlyOwner nonReentrant {
        address proposer = pendingPolicyProposer;
        if (proposer == address(0)) revert NoPendingPolicy();
        if (expectedPolicyHash != pendingPolicyHash) revert UnexpectedPolicy();
        if (block.timestamp < pendingPolicyAt) revert PolicyNotReady(pendingPolicyAt);
        if (!_isOwner(proposer)) revert ProposerNoLongerOwner();
        Policy memory nextPolicy = pendingPolicy;
        policy = nextPolicy;
        _clearPendingPolicy();
        // Tightened policy takes effect immediately, without erasing already-spent daily budget.
        uint256 nextLimit = maxWithdrawal > nextPolicy.maxClaimCeiling ? nextPolicy.maxClaimCeiling : maxWithdrawal;
        uint256 nextCooldown = withdrawalInterval < nextPolicy.minCooldown ? nextPolicy.minCooldown : withdrawalInterval;
        _setOperationalLimits(nextLimit, nextCooldown);
        emit PolicyApplied(msg.sender, keccak256(abi.encode(nextPolicy)));
    }

    /// @notice Recover credited payout funds while paused, only to the active recovery recipient.
    function emergencyWithdraw(uint256 amount) external onlyOwner whenPaused nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (amount > currencyHeldByJar) revert InsufficientCredit();
        _requireSolvent();
        currencyHeldByJar -= amount;
        address recipient = policy.recoveryRecipient;
        _transferExact(CURRENCY, recipient, amount);
        emit EmergencyWithdrawal(msg.sender, recipient, CURRENCY, amount);
    }

    /// @notice Recover uncredited tokens or forced native currency without consuming claim credit.
    /// @param token The token to recover, or address(0) for forced native currency.
    function recoverSurplus(address token, uint256 amount) external onlyOwner whenPaused nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _requireSolvent();
        address recipient = policy.recoveryRecipient;
        if (token == address(0)) {
            if (amount > address(this).balance) revert InsufficientSurplus();
            (bool sent,) = recipient.call{value: amount}("");
            if (!sent) revert NativeTransferFailed();
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 available = token == CURRENCY ? balance - currencyHeldByJar : balance;
            if (amount > available) revert InsufficientSurplus();
            _transferExact(token, recipient, amount);
        }
        emit SurplusRecovered(msg.sender, recipient, token, amount);
    }

    /// @notice Whether an account currently has owner authority, excluding the legacy garden account.
    function isOwner(address account) external view returns (bool) {
        return _isOwner(account);
    }

    /// @notice Whether an account currently has operational authority.
    function isOperator(address account) external view returns (bool) {
        return _isOwner(account) || _isSteward(account);
    }

    function _isOwner(address account) internal view returns (bool) {
        return account != GARDEN && account != address(0) && IGardenHats(HATS).isWearerOfHat(account, OWNER_HAT);
    }

    function _isSteward(address account) internal view returns (bool) {
        return account != GARDEN && account != address(0) && IGardenHats(HATS).isWearerOfHat(account, STEWARD_HAT);
    }

    function _setOperationalLimits(uint256 claimLimit, uint256 cooldown) private {
        if (claimLimit == 0 || claimLimit > policy.maxClaimCeiling || cooldown < policy.minCooldown) {
            revert InvalidOperationalLimits();
        }
        maxWithdrawal = claimLimit;
        withdrawalInterval = cooldown;
        emit OperationalLimitsChanged(msg.sender, claimLimit, cooldown);
    }

    function _validatePolicy(Policy memory candidate) private view {
        if (
            candidate.maxClaimCeiling == 0 || candidate.minCooldown == 0 ||
            candidate.recoveryRecipient == address(0) || candidate.recoveryRecipient == GARDEN ||
            candidate.recoveryRecipient == address(this)
        ) revert InvalidPolicy();
    }

    function _clearPendingPolicy() private {
        delete pendingPolicy;
        delete pendingPolicyProposer;
        delete pendingPolicyAt;
        delete pendingPolicyHash;
    }

    function _requireSolvent() private view {
        if (IERC20(CURRENCY).balanceOf(address(this)) < currencyHeldByJar) revert InsolventJar();
    }

    function _transferExact(address asset, address recipient, uint256 amount) private {
        IERC20 token = IERC20(asset);
        uint256 jarBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        uint256 recipientAfter = token.balanceOf(recipient);
        if (
            token.balanceOf(address(this)) != jarBefore - amount || recipientAfter < recipientBefore ||
            recipientAfter - recipientBefore != amount
        ) revert UnsupportedTokenTransfer();
    }
}
