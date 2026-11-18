// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {GardenCookieJar} from "../src/GardenCookieJar.sol";

contract GardenHatsMock {
    mapping(uint256 => mapping(address => bool)) public wearers;

    function setWearer(uint256 hat, address account, bool wears) external {
        wearers[hat][account] = wears;
    }

    function isWearerOfHat(address account, uint256 hat) external view returns (bool) {
        return wearers[hat][account];
    }
}

contract GardenTokenMock is ERC20 {
    uint8 private tokenDecimals;
    uint256 public feeBps;
    bool public unavailable;
    address public callbackTarget;
    bytes public callbackData;
    bool public lastCallbackSucceeded;
    error TokenUnavailable();

    constructor(uint8 decimals_) ERC20("Garden payout", "PAYOUT") {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function setDecimals(uint8 decimals_) external {
        tokenDecimals = decimals_;
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        if (unavailable) revert TokenUnavailable();
        uint256 fee = value * feeBps / 10_000;
        super._update(from, to, value - fee);
        if (fee != 0) super._update(from, address(0), fee);
        address target = callbackTarget;
        if (target != address(0)) {
            callbackTarget = address(0);
            (lastCallbackSucceeded,) = target.call(callbackData);
        }
    }
}

contract RejectNativeRecovery {
    receive() external payable {
        revert();
    }
}

contract GardenCookieJarTest is Test {
    GardenHatsMock internal hats;
    GardenTokenMock internal token;
    GardenCookieJar internal jar;
    address internal garden = address(0x100);
    address internal gardener = address(0x101);
    address internal steward = address(0x102);
    address internal owner = address(0x103);
    address internal recovery = address(0x104);

    function setUp() public {
        vm.warp(10 days);
        hats = new GardenHatsMock();
        token = new GardenTokenMock(6);
        hats.setWearer(1, gardener, true);
        hats.setWearer(2, steward, true);
        hats.setWearer(3, owner, true);
        jar = new GardenCookieJar(_config());
        token.mint(address(this), 1_000e6);
        token.approve(address(jar), type(uint256).max);
    }

    function test_Deposit_CreditsExactlyReceivedSixDecimalTokens() public {
        jar.deposit(100e6);
        assertEq(jar.currencyHeldByJar(), 100e6);
        assertEq(token.balanceOf(address(jar)), 100e6);
    }

    function test_Deposit_RejectsZeroNativeValueAndPausedFunding() public {
        vm.expectRevert(GardenCookieJar.InvalidAmount.selector);
        jar.deposit(0);
        vm.deal(address(this), 1 ether);
        (bool acceptsNative,) = address(jar).call{value: 1}(abi.encodeCall(jar.deposit, (1)));
        assertFalse(acceptsNative);
        vm.prank(steward);
        jar.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        jar.deposit(1e6);
        assertEq(jar.currencyHeldByJar(), 0);
        assertEq(token.balanceOf(address(jar)), 0);
    }

    function test_Accounting_EighteenDecimalAssetUsesRawTokenUnits() public {
        GardenTokenMock weth = new GardenTokenMock(18);
        GardenCookieJar.Config memory config = _config();
        config.asset = address(weth);
        config.policy = GardenCookieJar.Policy(2 ether, 1 days, 3 ether, recovery);
        config.maxWithdrawal = 1 ether;
        GardenCookieJar wethJar = new GardenCookieJar(config);
        weth.mint(address(this), 4 ether);
        weth.approve(address(wethJar), 4 ether);
        wethJar.deposit(4 ether);
        vm.prank(gardener);
        wethJar.withdraw(1 ether, "Eighteen decimals");
        assertEq(weth.balanceOf(gardener), 1 ether);
        assertEq(wethJar.currencyHeldByJar(), 3 ether);
    }

    function test_Claims_UseLiveHatAndPreserveCooldownOnRevocation() public {
        jar.deposit(100e6);
        vm.prank(gardener);
        jar.withdraw(10e6, "Garden tools");
        assertEq(token.balanceOf(gardener), 10e6);
        assertEq(jar.currencyHeldByJar(), 90e6);
        hats.setWearer(1, gardener, false);
        vm.prank(gardener);
        vm.expectRevert(GardenCookieJar.NotGardener.selector);
        jar.withdraw(1e6, "Revoked");
        hats.setWearer(1, gardener, true);
        vm.prank(gardener);
        vm.expectRevert(abi.encodeWithSelector(GardenCookieJar.ClaimTooSoon.selector, 11 days));
        jar.withdraw(1e6, "Still cooling down");
        vm.warp(11 days);
        vm.prank(gardener);
        jar.withdraw(10e6, "Next claim");
        assertEq(jar.totalWithdrawn(gardener), 20e6);
    }

    function test_Claims_RejectNonGardenerOverLimitAndOversizePurpose() public {
        jar.deposit(100e6);
        vm.prank(steward);
        vm.expectRevert(GardenCookieJar.NotGardener.selector);
        jar.withdraw(1e6, "Not automatically a gardener");
        vm.startPrank(gardener);
        vm.expectRevert(GardenCookieJar.ClaimExceedsLimit.selector);
        jar.withdraw(11e6, "Too much");
        vm.expectRevert(GardenCookieJar.InvalidAmount.selector);
        jar.withdraw(0, "Zero");
        vm.expectRevert(GardenCookieJar.InvalidPurpose.selector);
        jar.withdraw(1e6, string(new bytes(513)));
        vm.stopPrank();
    }

    function test_Operations_StewardCanAdjustWithinBoundsAndPauseButNotResumeOrRecover() public {
        vm.startPrank(steward);
        jar.setOperationalLimits(20e6, 2 days);
        vm.expectRevert(GardenCookieJar.InvalidOperationalLimits.selector);
        jar.setOperationalLimits(21e6, 2 days);
        vm.expectRevert(GardenCookieJar.InvalidOperationalLimits.selector);
        jar.setOperationalLimits(1e6, 1 hours);
        jar.pause();
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.unpause();
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.emergencyWithdraw(1);
        vm.stopPrank();
        vm.prank(owner);
        jar.unpause();
        assertFalse(jar.paused());
        assertEq(jar.maxWithdrawal(), 20e6);
        assertEq(jar.withdrawalInterval(), 2 days);
    }

    function test_Operations_RevokedStewardAndLegacyGardenCannotAdminister() public {
        hats.setWearer(2, steward, false);
        vm.prank(steward);
        vm.expectRevert(GardenCookieJar.NotOperator.selector);
        jar.pause();
        hats.setWearer(2, garden, true);
        hats.setWearer(3, garden, true);
        assertFalse(jar.isOwner(garden));
        assertFalse(jar.isOperator(garden));
        vm.startPrank(garden);
        vm.expectRevert(GardenCookieJar.NotOperator.selector);
        jar.pause();
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.proposePolicy(_policy());
        vm.stopPrank();
    }

    function test_Policy_NoticePeriodAndOwnerOnlyExecution() public {
        GardenCookieJar.Policy memory next = GardenCookieJar.Policy(5e6, 2 days, 10e6, address(0x200));
        bytes32 expectedPolicy = keccak256(abi.encode(next));
        vm.prank(steward);
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.proposePolicy(next);
        vm.prank(owner);
        jar.proposePolicy(next);
        assertEq(jar.pendingPolicyAt(), 12 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GardenCookieJar.PolicyNotReady.selector, 12 days));
        jar.executePolicy(expectedPolicy);
        vm.warp(12 days);
        vm.prank(steward);
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.executePolicy(expectedPolicy);
        vm.prank(owner);
        jar.executePolicy(expectedPolicy);
        assertEq(jar.maxWithdrawal(), 5e6);
        assertEq(jar.withdrawalInterval(), 2 days);
        (uint256 ceiling, uint256 minCooldown, uint256 budget, address recipient) = jar.policy();
        assertEq(ceiling, 5e6);
        assertEq(minCooldown, 2 days);
        assertEq(budget, 10e6);
        assertEq(recipient, address(0x200));
        assertEq(jar.pendingPolicyProposer(), address(0));
        vm.prank(owner);
        vm.expectRevert(GardenCookieJar.NoPendingPolicy.selector);
        jar.executePolicy(expectedPolicy);
    }

    function test_Policy_RevokedProposerCannotLeaveExecutableProposal() public {
        bytes32 expectedPolicy = keccak256(abi.encode(_policy()));
        vm.prank(owner);
        jar.proposePolicy(_policy());
        hats.setWearer(3, owner, false);
        address replacement = address(0x300);
        hats.setWearer(3, replacement, true);
        vm.warp(12 days);
        vm.prank(owner);
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.executePolicy(expectedPolicy);
        vm.startPrank(replacement);
        vm.expectRevert(GardenCookieJar.ProposerNoLongerOwner.selector);
        jar.executePolicy(expectedPolicy);
        jar.cancelPolicy();
        vm.expectRevert(GardenCookieJar.NoPendingPolicy.selector);
        jar.executePolicy(expectedPolicy);
        jar.proposePolicy(_policy());
        vm.warp(14 days);
        jar.executePolicy(expectedPolicy);
        vm.stopPrank();
    }

    function test_Policy_DoesNotResetSameDaySpendingOrClaimClocks() public {
        jar.deposit(100e6);
        GardenCookieJar.Policy memory next = GardenCookieJar.Policy(20e6, 1 days, 10e6, recovery);
        vm.prank(owner);
        jar.proposePolicy(next);
        vm.warp(12 days);
        vm.prank(gardener);
        jar.withdraw(10e6, "Before policy activation");
        vm.prank(owner);
        jar.executePolicy(keccak256(abi.encode(next)));
        assertEq(jar.claimedToday(), 10e6);
        assertEq(jar.lastWithdrawalTime(gardener), 12 days);
        address secondGardener = address(0x301);
        hats.setWearer(1, secondGardener, true);
        vm.prank(secondGardener);
        vm.expectRevert(GardenCookieJar.DailyBudgetExceeded.selector);
        jar.withdraw(1e6, "Budget already spent");
    }

    function test_Policy_ExecutionBindsReviewedPayloadAfterReplacement() public {
        GardenCookieJar.Policy memory first = _policy();
        bytes32 reviewedHash = keccak256(abi.encode(first));
        vm.prank(owner);
        jar.proposePolicy(first);
        GardenCookieJar.Policy memory replacement = first;
        replacement.dailyBudget = 50e6;
        vm.prank(owner);
        jar.proposePolicy(replacement);
        vm.warp(12 days);
        vm.prank(owner);
        vm.expectRevert(GardenCookieJar.UnexpectedPolicy.selector);
        jar.executePolicy(reviewedHash);
        assertEq(jar.pendingPolicyHash(), keccak256(abi.encode(replacement)));
    }

    function test_DailyBudget_AggregatesAllClaimantsAndResetsAtUtcDayBoundary() public {
        jar.deposit(100e6);
        for (uint256 i = 1; i <= 3; ++i) {
            address claimant = address(uint160(0x400 + i));
            hats.setWearer(1, claimant, true);
            vm.prank(claimant);
            jar.withdraw(10e6, "Shared daily budget");
        }
        vm.prank(gardener);
        vm.expectRevert(GardenCookieJar.DailyBudgetExceeded.selector);
        jar.withdraw(1e6, "Budget exhausted");
        vm.warp(11 days);
        vm.prank(gardener);
        jar.withdraw(10e6, "New day");
        assertEq(jar.claimedToday(), 10e6);
        assertEq(jar.budgetDay(), 11);
    }

    function test_Recovery_CreditAndSurplusAreSeparateAndRecipientIsFixed() public {
        jar.deposit(100e6);
        token.transfer(address(jar), 7e6);
        vm.prank(owner);
        jar.pause();
        vm.startPrank(owner);
        vm.expectRevert(GardenCookieJar.InsufficientSurplus.selector);
        jar.recoverSurplus(address(token), 8e6);
        jar.recoverSurplus(address(token), 7e6);
        assertEq(jar.currencyHeldByJar(), 100e6);
        jar.emergencyWithdraw(20e6);
        vm.stopPrank();
        assertEq(jar.currencyHeldByJar(), 80e6);
        assertEq(token.balanceOf(address(jar)), 80e6);
        assertEq(token.balanceOf(recovery), 27e6);
        assertEq(token.balanceOf(owner), 0);
    }

    function test_Recovery_RejectsInvalidRecipientAndRequiresPause() public {
        jar.deposit(100e6);
        vm.startPrank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        jar.emergencyWithdraw(1e6);
        GardenCookieJar.Policy memory next = _policy();
        next.recoveryRecipient = garden;
        vm.expectRevert(GardenCookieJar.InvalidPolicy.selector);
        jar.proposePolicy(next);
        next.recoveryRecipient = address(jar);
        vm.expectRevert(GardenCookieJar.InvalidPolicy.selector);
        jar.proposePolicy(next);
        next.recoveryRecipient = address(0);
        vm.expectRevert(GardenCookieJar.InvalidPolicy.selector);
        jar.proposePolicy(next);
        vm.stopPrank();
    }

    function test_Recovery_UnrelatedTokensAndForcedNativeDoNotChangeCredit() public {
        jar.deposit(100e6);
        GardenTokenMock other = new GardenTokenMock(18);
        other.mint(address(jar), 3 ether);
        vm.deal(address(jar), 2 ether);
        vm.startPrank(owner);
        jar.pause();
        jar.recoverSurplus(address(other), 3 ether);
        jar.recoverSurplus(address(0), 2 ether);
        vm.stopPrank();
        assertEq(other.balanceOf(recovery), 3 ether);
        assertEq(recovery.balance, 2 ether);
        assertEq(jar.currencyHeldByJar(), 100e6);
    }

    function test_Recovery_RevertingNativeRecipientPreservesForcedFundsAndCredit() public {
        GardenCookieJar.Config memory config = _config();
        config.policy.recoveryRecipient = address(new RejectNativeRecovery());
        GardenCookieJar rejectingJar = new GardenCookieJar(config);
        token.approve(address(rejectingJar), 100e6);
        rejectingJar.deposit(100e6);
        vm.deal(address(rejectingJar), 1 ether);
        vm.startPrank(owner);
        rejectingJar.pause();
        vm.expectRevert(GardenCookieJar.NativeTransferFailed.selector);
        rejectingJar.recoverSurplus(address(0), 1 ether);
        vm.stopPrank();
        assertEq(address(rejectingJar).balance, 1 ether);
        assertEq(rejectingJar.currencyHeldByJar(), 100e6);
    }

    function test_Accounting_RejectsShortDepositAndRollsBackTransfer() public {
        token.setFee(100);
        vm.expectRevert(GardenCookieJar.UnsupportedTokenTransfer.selector);
        jar.deposit(100e6);
        assertEq(jar.currencyHeldByJar(), 0);
        assertEq(token.balanceOf(address(jar)), 0);
        assertEq(token.balanceOf(address(this)), 1_000e6);
    }

    function test_Accounting_RejectsShortClaimAndPreservesClocksBudgetAndCredit() public {
        jar.deposit(100e6);
        token.setFee(100);
        vm.prank(gardener);
        vm.expectRevert(GardenCookieJar.UnsupportedTokenTransfer.selector);
        jar.withdraw(10e6, "Taxed payout");
        assertEq(jar.currencyHeldByJar(), 100e6);
        assertEq(jar.lastWithdrawalTime(gardener), 0);
        assertEq(jar.totalWithdrawn(gardener), 0);
        assertEq(jar.claimedToday(), 0);
        assertEq(token.balanceOf(gardener), 0);
        assertEq(token.balanceOf(address(jar)), 100e6);
    }

    function test_Accounting_PausedTokenRollsBackClaimsAndRecovery() public {
        jar.deposit(100e6);
        token.setUnavailable(true);
        vm.prank(gardener);
        vm.expectRevert(GardenTokenMock.TokenUnavailable.selector);
        jar.withdraw(10e6, "Token paused");
        assertEq(jar.lastWithdrawalTime(gardener), 0);
        vm.startPrank(owner);
        jar.pause();
        vm.expectRevert(GardenTokenMock.TokenUnavailable.selector);
        jar.emergencyWithdraw(10e6);
        vm.stopPrank();
        assertEq(jar.currencyHeldByJar(), 100e6);
        assertEq(token.balanceOf(address(jar)), 100e6);
    }

    function test_Accounting_InsolvencyCannotConsumeCreditOrExtractOtherAssets() public {
        jar.deposit(100e6);
        token.burn(address(jar), 1);
        vm.prank(gardener);
        vm.expectRevert(GardenCookieJar.InsolventJar.selector);
        jar.withdraw(1, "Unbacked credit");
        vm.startPrank(owner);
        jar.pause();
        vm.expectRevert(GardenCookieJar.InsolventJar.selector);
        jar.recoverSurplus(address(token), 1);
        vm.expectRevert(GardenCookieJar.InsolventJar.selector);
        jar.emergencyWithdraw(1);
        vm.expectRevert(GardenCookieJar.InsolventJar.selector);
        jar.unpause();
        vm.stopPrank();
        assertEq(jar.currencyHeldByJar(), 100e6);
    }

    function test_Accounting_CallbackCannotReenterAnotherClaim() public {
        jar.deposit(100e6);
        hats.setWearer(1, address(token), true);
        token.setCallback(address(jar), abi.encodeCall(jar.withdraw, (1e6, "Reentrant claim")));
        vm.prank(gardener);
        jar.withdraw(10e6, "Single claim");
        assertFalse(token.lastCallbackSucceeded());
        assertEq(token.callbackTarget(), address(0));
        assertEq(jar.currencyHeldByJar(), 90e6);
        assertEq(token.balanceOf(gardener), 10e6);
        assertEq(jar.totalWithdrawn(address(token)), 0);
    }

    function test_Claims_AtTimestampZeroStillHaveCooldown() public {
        vm.warp(0);
        jar.deposit(100e6);
        vm.prank(gardener);
        jar.withdraw(10e6, "Timestamp zero");
        vm.prank(gardener);
        vm.expectRevert(abi.encodeWithSelector(GardenCookieJar.ClaimTooSoon.selector, 1 days));
        jar.withdraw(1e6, "Second claim");
    }

    function testFuzz_Accounting_DepositClaimRecoveryConservesTokens(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 10e6);
        jar.deposit(100e6);
        vm.prank(gardener);
        jar.withdraw(amount, "Conservation");
        vm.startPrank(owner);
        jar.pause();
        jar.emergencyWithdraw(100e6 - amount);
        vm.stopPrank();
        assertEq(jar.currencyHeldByJar(), 0);
        assertEq(token.balanceOf(address(jar)), 0);
        assertEq(token.balanceOf(gardener) + token.balanceOf(recovery), 100e6);
    }

    function _policy() internal view returns (GardenCookieJar.Policy memory) {
        return GardenCookieJar.Policy(20e6, 1 days, 30e6, recovery);
    }

    function _config() internal view returns (GardenCookieJar.Config memory) {
        return GardenCookieJar.Config({
            garden: garden,
            asset: address(token),
            hats: address(hats),
            gardenerHat: 1,
            stewardHat: 2,
            ownerHat: 3,
            policy: GardenCookieJar.Policy(20e6, 1 days, 30e6, recovery),
            maxWithdrawal: 10e6,
            withdrawalInterval: 1 days
        });
    }
}
