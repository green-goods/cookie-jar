// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GardenCookieJar} from "../src/GardenCookieJar.sol";
import {GardenCookieJarFactory} from "../src/GardenCookieJarFactory.sol";
import {GardenHatsMock, GardenTokenMock} from "./GardenCookieJar.t.sol";

contract GardenCookieJarFactoryTest is Test {
    GardenCookieJarFactory internal factory;
    GardenHatsMock internal hats;
    GardenTokenMock internal usdc;
    address internal governance = address(0x501);
    address internal registrar = address(0x502);
    address internal garden = address(0x503);
    address internal owner = address(0x504);

    function setUp() public {
        hats = new GardenHatsMock();
        usdc = new GardenTokenMock(6);
        hats.setWearer(3, owner, true);
        factory = new GardenCookieJarFactory(governance, registrar, address(hats));
        vm.prank(governance);
        factory.setAssetAdmission(address(usdc), 6, true);
    }

    function test_Create_DeterministicAddressAndImmutableProvenance() public {
        GardenCookieJar.Config memory config = _config();
        address predicted = factory.predictJarAddress(config, 1);
        vm.prank(registrar);
        address created = factory.createJar(config, 1);
        assertEq(created, predicted);
        assertEq(factory.jarFor(garden, address(usdc), 1), created);
        assertTrue(factory.isFactoryJar(created));
        GardenCookieJar jar = GardenCookieJar(created);
        assertEq(jar.GARDEN(), garden);
        assertEq(jar.HATS(), address(hats));
        assertEq(jar.CURRENCY(), address(usdc));
        assertEq(jar.FACTORY(), address(factory));
        assertEq(jar.GARDENER_HAT(), 1);
        assertEq(jar.STEWARD_HAT(), 2);
        assertEq(jar.OWNER_HAT(), 3);
    }

    function test_Create_RegistrarOnlyAndCannotReplaceExistingGeneration() public {
        GardenCookieJar.Config memory config = _config();
        vm.expectRevert(GardenCookieJarFactory.NotRegistrar.selector);
        factory.createJar(config, 1);
        vm.startPrank(registrar);
        factory.createJar(config, 1);
        config.maxWithdrawal = 5e6;
        vm.expectRevert(GardenCookieJarFactory.JarAlreadyExists.selector);
        factory.createJar(config, 1);
        address secondGeneration = factory.createJar(config, 2);
        vm.stopPrank();
        assertTrue(secondGeneration != factory.jarFor(garden, address(usdc), 1));
    }

    function test_Create_PredictionCommitsToPolicyRolesRegistrarAndGeneration() public {
        GardenCookieJar.Config memory config = _config();
        address first = factory.predictJarAddress(config, 1);
        assertTrue(first != factory.predictJarAddress(config, 2));
        config.policy.recoveryRecipient = address(0x505);
        assertTrue(first != factory.predictJarAddress(config, 1));
        config = _config();
        config.ownerHat = 99;
        assertTrue(first != factory.predictJarAddress(config, 1));
        config = _config();
        vm.prank(governance);
        factory.setRegistrar(address(0x506));
        assertTrue(first != factory.predictJarAddress(config, 1));
        vm.prank(registrar);
        vm.expectRevert(GardenCookieJarFactory.NotRegistrar.selector);
        factory.createJar(config, 1);
    }

    function test_Create_RequiresExplicitAdmissionAndCurrentDecimals() public {
        GardenCookieJar.Config memory config = _config();
        GardenTokenMock weth = new GardenTokenMock(18);
        config.asset = address(weth);
        vm.prank(registrar);
        vm.expectRevert(GardenCookieJarFactory.AssetNotAdmitted.selector);
        factory.createJar(config, 1);
        vm.prank(governance);
        vm.expectRevert(GardenCookieJarFactory.TokenDecimalsChanged.selector);
        factory.setAssetAdmission(address(weth), 6, true);
        vm.prank(governance);
        factory.setAssetAdmission(address(weth), 18, true);
        vm.prank(registrar);
        address jar = factory.createJar(config, 1);
        assertEq(GardenCookieJar(jar).CURRENCY(), address(weth));
        usdc.setDecimals(18);
        vm.prank(registrar);
        vm.expectRevert(GardenCookieJarFactory.TokenDecimalsChanged.selector);
        factory.createJar(_config(), 1);
    }

    function test_Governance_NoImplicitJarAuthorityAndCreationPauseDoesNotPauseJars() public {
        vm.prank(registrar);
        GardenCookieJar jar = GardenCookieJar(factory.createJar(_config(), 1));
        assertFalse(jar.isOwner(governance));
        assertFalse(jar.isOwner(registrar));
        assertFalse(jar.isOwner(address(factory)));
        vm.prank(governance);
        vm.expectRevert(GardenCookieJar.NotOperator.selector);
        jar.pause();
        vm.prank(governance);
        factory.setCreationPaused(true);
        assertFalse(jar.paused());
        vm.prank(registrar);
        vm.expectRevert(GardenCookieJarFactory.CreationPaused.selector);
        factory.createJar(_config(), 2);
        usdc.mint(address(this), 10e6);
        usdc.approve(address(jar), 10e6);
        jar.deposit(10e6);
        assertEq(jar.currencyHeldByJar(), 10e6);
    }

    function test_Governance_AssetDisableOnlyStopsNewCreation() public {
        vm.prank(registrar);
        GardenCookieJar jar = GardenCookieJar(factory.createJar(_config(), 1));
        vm.prank(governance);
        factory.setAssetAdmission(address(usdc), 6, false);
        vm.prank(registrar);
        vm.expectRevert(GardenCookieJarFactory.AssetNotAdmitted.selector);
        factory.createJar(_config(), 2);
        hats.setWearer(1, address(this), true);
        usdc.mint(address(this), 10e6);
        usdc.approve(address(jar), 10e6);
        jar.deposit(10e6);
        jar.withdraw(10e6, "Existing jar remains usable");
        assertEq(usdc.balanceOf(address(this)), 10e6);
    }

    function test_Create_RejectsWrongHatsZeroRolesInvalidPolicyAndGeneration() public {
        GardenCookieJar.Config memory config = _config();
        config.hats = address(new GardenHatsMock());
        vm.startPrank(registrar);
        vm.expectRevert(GardenCookieJarFactory.InvalidConfiguration.selector);
        factory.createJar(config, 1);
        config = _config();
        vm.expectRevert(GardenCookieJarFactory.InvalidConfiguration.selector);
        factory.createJar(config, 0);
        config.ownerHat = 0;
        vm.expectRevert(GardenCookieJar.InvalidConfiguration.selector);
        factory.createJar(config, 1);
        config = _config();
        config.policy.recoveryRecipient = garden;
        vm.expectRevert(GardenCookieJar.InvalidPolicy.selector);
        factory.createJar(config, 1);
        vm.stopPrank();
        assertEq(factory.jarFor(garden, address(usdc), 1), address(0));
    }

    function test_Governance_RejectsUnauthorizedConfigurationAndZeroRegistrar() public {
        vm.expectRevert(GardenCookieJarFactory.NotGovernance.selector);
        factory.setCreationPaused(true);
        vm.expectRevert(GardenCookieJarFactory.NotGovernance.selector);
        factory.setRegistrar(address(this));
        vm.expectRevert(GardenCookieJarFactory.NotGovernance.selector);
        factory.setAssetAdmission(address(usdc), 6, false);
        vm.prank(governance);
        vm.expectRevert(GardenCookieJarFactory.InvalidConfiguration.selector);
        factory.setRegistrar(address(0));
    }

    function _config() private view returns (GardenCookieJar.Config memory) {
        return GardenCookieJar.Config({
            garden: garden,
            asset: address(usdc),
            hats: address(hats),
            gardenerHat: 1,
            stewardHat: 2,
            ownerHat: 3,
            policy: GardenCookieJar.Policy(20e6, 1 days, 30e6, address(0x507)),
            maxWithdrawal: 10e6,
            withdrawalInterval: 1 days
        });
    }
}
