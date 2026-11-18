// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {GardenCookieJar} from "../../src/GardenCookieJar.sol";
import {GardenCookieJarFactory} from "../../src/GardenCookieJarFactory.sol";

interface ITasHatsModule {
    function getGardenHatIds(address garden)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, bool);
    function isOwnerOf(address garden, address account) external view returns (bool);
    function isStewardOf(address garden, address account) external view returns (bool);
    function grantRole(address garden, address account, uint8 role) external;
    function revokeRole(address garden, address account, uint8 role) external;
}

interface ITasHats {
    function isWearerOfHat(address account, uint256 hat) external view returns (bool);
}

interface ITasGardenToken {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isGardenAccount(address account) external view returns (bool);
}

interface ITasJarRegistry {
    function getGardenJars(address garden) external view returns (address[] memory);
    function getGardenJar(address garden, address asset) external view returns (address);
}

interface ITasYieldResolver {
    function gardenTreasuries(address garden) external view returns (address);
    function gardenVaults(address garden, address asset) external view returns (address);
}

interface ITasVault {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface ITasWrappedEther {
    function deposit() external payable;
}

/// @notice Opt-in conformance pilot against real TAS Hats and payout tokens.
/// @dev Verify the pinned L2 header via RPC before running with RUN_TAS_HATS_FORK=true through
///      the repository Bun wrapper. This suite does not
///      activate the jars in the production registry or prove a vault harvest. WETH uses fork-only
///      ETH, DAI/USDC balances are injected, and existing role holders are impersonated locally.
contract TasGardenCookieJarForkTest is Test {
    uint256 private constant FORK_BLOCK = 522_211_968;
    uint256 private constant FORK_L1_BLOCK = 26_366_125;
    uint256 private constant FORK_TIMESTAMP = 1_794_092_427;
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private constant TAS = 0xA2DF8Eb73444A3f3cf9b8E3749313C7471d7D5E3;
    address private constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address private constant HATS_MODULE = 0x5b943088ecdDBF8E4ae387348A88A654aC5F7266;
    address private constant GARDEN_TOKEN = 0xe1Da335110b1ed48e7df63209f5D424d02276593;
    address private constant JAR_MODULE = 0x726bfbd0B7449C8f4aBfbcc2FBC5a89eB18fF157;
    address private constant RESOLVER = 0x90896C86108528abB600Da3C48a1aa054958bDeb;
    address private constant GOVERNANCE = 0x1B9Ac97Ea62f69521A14cbe6F45eb24aD6612C19;
    address private constant TAS_OWNER = 0x6855B23D93f57851d30a324B00f17f9baf34Ac02;
    address private constant TAS_STEWARD = 0x2aa64E6d80390F5C017F0313cB908051BE2FD35e;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant OLD_WETH_JAR = 0x69C56D8f7b6c7feaA9Bf2D91285ED2b141B84cCa;
    address private constant OLD_DAI_JAR = 0x91cDcD4B620d82cCC97EC5aE7Ee7B4b833d16021;

    uint256 private constant OWNER_HAT = 0x0000005c00020001000300010000000000000000000000000000000000000000;
    uint256 private constant STEWARD_HAT = 0x0000005c00020001000300020000000000000000000000000000000000000000;
    uint256 private constant GARDENER_HAT = 0x0000005c00020001000300040000000000000000000000000000000000000000;
    uint8 private constant GARDENER_ROLE = 0;
    uint8 private constant STEWARD_ROLE = 2;
    uint8 private constant OWNER_ROLE = 3;

    GardenCookieJarFactory private factory;
    GardenCookieJar private wethJar;
    GardenCookieJar private daiJar;
    bytes32 private preservedStateBeforeDeployment;
    ITasHatsModule private constant hatsModule = ITasHatsModule(HATS_MODULE);

    function setUp() public {
        if (!vm.envOr("RUN_TAS_HATS_FORK", false)) {
            vm.skip(true, "TAS fork not run: set RUN_TAS_HATS_FORK=true and provide an archive RPC");
            return;
        }
        vm.createSelectFork(vm.envOr("TAS_HATS_RPC_URL", string("arbitrum")), FORK_BLOCK);
        assertEq(vm.getChainId(), 42_161);
        // Arbitrum reports the L1 height in the execution environment. The RPC preflight
        // verifies the L2 header and this call selects its exact height.
        assertEq(vm.getBlockNumber(), FORK_L1_BLOCK);
        assertEq(vm.getBlockTimestamp(), FORK_TIMESTAMP);
        _assertRuntimePins();
        _assertLiveRoles();
        preservedStateBeforeDeployment = _preservedState();

        // The existing protocol Safe controls asset admission only. The test contract is the
        // fork registrar; production registration is a separate, unproven migration boundary.
        factory = new GardenCookieJarFactory(GOVERNANCE, address(this), HATS);
        vm.startPrank(GOVERNANCE);
        factory.setAssetAdmission(WETH, 18, true);
        factory.setAssetAdmission(DAI, 18, true);
        factory.setAssetAdmission(USDC, 6, true);
        vm.stopPrank();
        wethJar = GardenCookieJar(factory.createJar(_config(WETH, 0.01 ether, 0.02 ether, 0.1 ether), 1));
        daiJar = GardenCookieJar(factory.createJar(_config(DAI, 10 ether, 20 ether, 100 ether), 1));
    }

    function test_Fork_DeploysPairWithLiveHatsAndPreservesIdentityAndFleet() public {
        _assertJar(wethJar, WETH, 0.01 ether);
        _assertJar(daiJar, DAI, 10 ether);
        assertTrue(address(wethJar) != address(daiJar));
        assertEq(factory.jarFor(TAS, WETH, 1), address(wethJar));
        assertEq(factory.jarFor(TAS, DAI, 1), address(daiJar));
        assertTrue(factory.isFactoryJar(address(wethJar)));
        assertTrue(factory.isFactoryJar(address(daiJar)));

        _fund(wethJar, 0.1 ether);
        vm.prank(TAS_OWNER);
        wethJar.withdraw(0.01 ether, "Fork-only TAS gardener payout");
        assertEq(_preservedState(), preservedStateBeforeDeployment);

        // Deployment alone never changes app discovery or the resolver's active registry.
        assertEq(ITasJarRegistry(JAR_MODULE).getGardenJars(TAS).length, 0);
        assertEq(ITasJarRegistry(JAR_MODULE).getGardenJar(TAS, WETH), address(0));
        assertEq(ITasJarRegistry(JAR_MODULE).getGardenJar(TAS, DAI), address(0));
        emit log_named_address("Fork factory (not a production prediction)", address(factory));
        emit log_named_address("Fork TAS WETH jar", address(wethJar));
        emit log_named_address("Fork TAS DAI jar", address(daiJar));
    }

    function test_Fork_RealTokensCreditAndPayAnExistingGardener() public {
        _fund(wethJar, 0.1 ether);
        _fund(daiJar, 100 ether);
        _claimAndAssert(wethJar, TAS_OWNER, 0.01 ether);
        _claimAndAssert(daiJar, TAS_OWNER, 10 ether);
        vm.expectRevert();
        vm.prank(TAS_OWNER);
        daiJar.withdraw(1 ether, "Second claim is inside the existing cooldown");
        vm.expectRevert();
        daiJar.withdraw(1 ether, "The registrar has no gardener authority");
    }

    function test_Fork_StewardsOperateWithinOwnerPolicyAndCannotRecover() public {
        vm.startPrank(TAS_STEWARD);
        daiJar.setOperationalLimits(15 ether, 2 days);
        vm.expectRevert();
        daiJar.setOperationalLimits(21 ether, 2 days);
        vm.expectRevert();
        daiJar.setOperationalLimits(10 ether, 12 hours);
        daiJar.pause();
        vm.expectRevert();
        daiJar.unpause();
        vm.expectRevert();
        daiJar.proposePolicy(GardenCookieJar.Policy(30 ether, 1 days, 100 ether, GOVERNANCE));
        vm.expectRevert();
        daiJar.emergencyWithdraw(1 ether);
        vm.stopPrank();
        assertEq(daiJar.maxWithdrawal(), 15 ether);
        assertEq(daiJar.withdrawalInterval(), 2 days);
        assertTrue(daiJar.paused());
        vm.prank(TAS_OWNER);
        daiJar.unpause();
        assertFalse(daiJar.paused());

        // Neither the old account nor the factory's governance gains jar authority by identity.
        vm.expectRevert();
        vm.prank(TAS);
        daiJar.pause();
        vm.expectRevert();
        vm.prank(TAS);
        hatsModule.grantRole(TAS, address(this), OWNER_ROLE);
        vm.expectRevert();
        vm.prank(TAS);
        hatsModule.grantRole(TAS, address(this), STEWARD_ROLE);
        vm.expectRevert();
        vm.prank(GOVERNANCE);
        daiJar.pause();
    }

    function test_Fork_LiveRoleRotationAndRevocationChangeAdministrationImmediately() public {
        address replacement = makeAddr("fork-only replacement TAS steward");
        vm.prank(TAS_OWNER);
        hatsModule.grantRole(TAS, replacement, STEWARD_ROLE);
        assertTrue(ITasHats(HATS).isWearerOfHat(replacement, STEWARD_HAT));
        vm.prank(replacement);
        daiJar.setOperationalLimits(5 ether, 2 days);
        vm.prank(TAS_OWNER);
        hatsModule.revokeRole(TAS, replacement, STEWARD_ROLE);
        assertFalse(ITasHats(HATS).isWearerOfHat(replacement, STEWARD_HAT));
        vm.expectRevert();
        vm.prank(replacement);
        daiJar.pause();
        assertEq(daiJar.maxWithdrawal(), 5 ether);
    }

    function test_Fork_RevokedOwnerCannotExecuteAnEarlierPolicyProposal() public {
        address replacement = makeAddr("fork-only replacement TAS owner");
        vm.prank(TAS_OWNER);
        hatsModule.grantRole(TAS, replacement, OWNER_ROLE);
        GardenCookieJar.Policy memory next = GardenCookieJar.Policy(30 ether, 1 days, 120 ether, GOVERNANCE);
        bytes32 reviewedPolicyHash = keccak256(abi.encode(next));
        vm.prank(replacement);
        daiJar.proposePolicy(next);
        vm.expectRevert();
        vm.prank(TAS_OWNER);
        daiJar.executePolicy(reviewedPolicyHash);
        vm.prank(TAS_OWNER);
        hatsModule.revokeRole(TAS, replacement, OWNER_ROLE);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert();
        vm.prank(TAS_OWNER);
        daiJar.executePolicy(reviewedPolicyHash);

        vm.startPrank(TAS_OWNER);
        daiJar.cancelPolicy();
        daiJar.proposePolicy(next);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(TAS_OWNER);
        daiJar.executePolicy(reviewedPolicyHash);
        (uint256 ceiling, uint256 cooldown, uint256 budget, address recovery) = daiJar.policy();
        assertEq(ceiling, 30 ether);
        assertEq(cooldown, 1 days);
        assertEq(budget, 120 ether);
        assertEq(recovery, GOVERNANCE);
    }

    function test_Fork_RecoveryPaysTheConfiguredDestinationAndPreservesCredit() public {
        _fund(daiJar, 100 ether);
        deal(DAI, address(this), 7 ether, false);
        IERC20(DAI).transfer(address(daiJar), 7 ether);
        uint256 treasuryBefore = IERC20(DAI).balanceOf(GOVERNANCE);
        uint256 ownerBefore = IERC20(DAI).balanceOf(TAS_OWNER);
        vm.expectRevert();
        vm.prank(TAS_OWNER);
        daiJar.emergencyWithdraw(10 ether);
        vm.prank(TAS_STEWARD);
        daiJar.pause();
        vm.startPrank(TAS_OWNER);
        daiJar.emergencyWithdraw(10 ether);
        daiJar.recoverSurplus(DAI, 7 ether);
        vm.expectRevert();
        daiJar.recoverSurplus(DAI, 1);
        vm.stopPrank();
        assertEq(IERC20(DAI).balanceOf(GOVERNANCE), treasuryBefore + 17 ether);
        assertEq(IERC20(DAI).balanceOf(TAS_OWNER), ownerBefore);
        assertEq(daiJar.currencyHeldByJar(), 90 ether);
        assertEq(IERC20(DAI).balanceOf(address(daiJar)), 90 ether);
    }

    function test_Fork_UsdcUsesSixDecimalsAndRealHatRevocation() public {
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        GardenCookieJar usdcJar = GardenCookieJar(factory.createJar(_config(USDC, 10e6, 20e6, 30e6), 1));
        address gardener = makeAddr("fork-only TAS USDC gardener");
        vm.prank(TAS_OWNER);
        hatsModule.grantRole(TAS, gardener, GARDENER_ROLE);
        _fund(usdcJar, 100e6);
        _claimAndAssert(usdcJar, gardener, 10e6);
        uint256 claimTime = usdcJar.lastWithdrawalTime(gardener);
        vm.prank(TAS_OWNER);
        hatsModule.revokeRole(TAS, gardener, GARDENER_ROLE);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert();
        vm.prank(gardener);
        usdcJar.withdraw(10e6, "A revoked gardener must not receive another payout");
        assertEq(usdcJar.currencyHeldByJar(), 90e6);
        assertEq(usdcJar.lastWithdrawalTime(gardener), claimTime);
        assertEq(ITasJarRegistry(JAR_MODULE).getGardenJar(TAS, USDC), address(0));
    }

    function _config(address asset, uint256 limit, uint256 ceiling, uint256 budget)
        private
        pure
        returns (GardenCookieJar.Config memory)
    {
        // All amounts and the protocol Safe recovery recipient are rehearsal fixtures, not
        // approved production policy. No new Safe or Hat is created by this configuration.
        return GardenCookieJar.Config({
            garden: TAS,
            asset: asset,
            hats: HATS,
            gardenerHat: GARDENER_HAT,
            stewardHat: STEWARD_HAT,
            ownerHat: OWNER_HAT,
            policy: GardenCookieJar.Policy(ceiling, 1 days, budget, GOVERNANCE),
            maxWithdrawal: limit,
            withdrawalInterval: 1 days
        });
    }

    function _fund(GardenCookieJar jar, uint256 amount) private {
        address asset = jar.CURRENCY();
        if (asset == WETH) {
            deal(address(this), amount);
            ITasWrappedEther(WETH).deposit{value: amount}();
        } else {
            // Isolated token fixtures: no real vault principal or treasury funds are used.
            deal(asset, address(this), amount, false);
        }
        IERC20(asset).approve(address(jar), amount);
        jar.deposit(amount);
        assertEq(jar.currencyHeldByJar(), amount);
        assertEq(IERC20(asset).balanceOf(address(jar)), amount);
        assertEq(IERC20(asset).allowance(address(this), address(jar)), 0);
    }

    function _claimAndAssert(GardenCookieJar jar, address gardener, uint256 amount) private {
        IERC20 token = IERC20(jar.CURRENCY());
        uint256 beforeBalance = token.balanceOf(gardener);
        uint256 beforeCredit = jar.currencyHeldByJar();
        vm.prank(gardener);
        jar.withdraw(amount, "Fork-only payout from the existing TAS gardener Hat");
        assertEq(token.balanceOf(gardener), beforeBalance + amount);
        assertEq(jar.currencyHeldByJar(), beforeCredit - amount);
        assertEq(token.balanceOf(address(jar)), beforeCredit - amount);
    }

    function _assertLiveRoles() private view {
        (uint256 ownerHat, uint256 stewardHat,, uint256 gardenerHat,,,, bool configured) =
            hatsModule.getGardenHatIds(TAS);
        assertTrue(configured);
        assertEq(ownerHat, OWNER_HAT);
        assertEq(stewardHat, STEWARD_HAT);
        assertEq(gardenerHat, GARDENER_HAT);
        assertTrue(hatsModule.isOwnerOf(TAS, TAS_OWNER));
        assertTrue(hatsModule.isStewardOf(TAS, TAS_STEWARD));
        assertFalse(hatsModule.isOwnerOf(TAS, TAS_STEWARD));
        assertTrue(ITasHats(HATS).isWearerOfHat(TAS_OWNER, GARDENER_HAT));
        assertFalse(hatsModule.isOwnerOf(TAS, TAS));
        assertFalse(hatsModule.isStewardOf(TAS, TAS));
        assertTrue(ITasGardenToken(GARDEN_TOKEN).isGardenAccount(TAS));
        assertEq(ITasGardenToken(GARDEN_TOKEN).ownerOf(2), TAS_OWNER);
        assertEq(ITasJarRegistry(JAR_MODULE).getGardenJars(TAS).length, 0);
    }

    function _assertJar(GardenCookieJar jar, address asset, uint256 limit) private view {
        assertEq(jar.GARDEN(), TAS);
        assertEq(jar.CURRENCY(), asset);
        assertEq(address(jar.HATS()), HATS);
        assertEq(jar.GARDENER_HAT(), GARDENER_HAT);
        assertEq(jar.STEWARD_HAT(), STEWARD_HAT);
        assertEq(jar.OWNER_HAT(), OWNER_HAT);
        assertEq(jar.FACTORY(), address(factory));
        assertEq(jar.maxWithdrawal(), limit);
        assertEq(jar.withdrawalInterval(), 1 days);
    }

    function _assertRuntimePins() private view {
        assertEq(HATS.codehash, 0x91b24bc822401959192fd43e8795e2c6e23db03cd375588ea4585417902f87b2);
        assertEq(TAS.codehash, 0x2adc1b2fd6b22076539ad0c7a265e57e2b49a60ac06f62395fb481391484b5e3);
        assertEq(WETH.codehash, 0x2d240bb4510ed1acfeaba905eb4bcc4524d63c8ae66e48fcccac55ea714db7a7);
        assertEq(DAI.codehash, 0xc98b96ae5d7eb1927fcc867d2d558f5e12503149075bebcc338316c7a5f0fe35);
        assertEq(USDC.codehash, 0xad30d819dbc47814b7e6cb837fd7cc57fcb591479a38596ee93de4fc52e8c435);
        _assertImplementation(HATS_MODULE, address(bytes20(hex"3df0061227ceb2c80f6f9f9d20ab44bc07b26a1b")),
            0xf5265e8931c73f0d4251da7b68008d636725555e6b3678dad8efc0326bb5f1b8);
        _assertImplementation(JAR_MODULE, 0xD71adDC905a147320D82e934360b0e0C82dd76aF,
            0x0d9a1cec2c5f110aa3d8f4e61868b2c36c7ec78093a2eafd7592040dc051e79c);
        _assertImplementation(GARDEN_TOKEN, address(bytes20(hex"18da22304d256707dda2914879324ff88e3280c3")),
            0x1f530946c3684513326f82ec7eb6eafa72001bc8b84b25b42f735029f2f5ae17);
        _assertImplementation(RESOLVER, address(bytes20(hex"810e41a6d52a76613078e830c0ea641ba23ba9a8")),
            0x9f2aaa961093ca3c9b4e7bae6925d94c5158afea789eba28e4ec46aec51446a7);
    }

    function _assertImplementation(address proxy, address expected, bytes32 runtimeHash) private view {
        assertEq(proxy.codehash, 0x60fd6321ecf59eb9beedf71da3689269f96cf3565fa30dc5dc84d89842516fe7);
        address implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        assertEq(implementation, expected);
        assertEq(implementation.codehash, runtimeHash);
    }

    function _preservedState() private view returns (bytes32 digest) {
        address[18] memory gardens = [
            address(bytes20(hex"f401f34378384713222d1d21f63359cc4e8a858a")),
            address(bytes20(hex"f7b892886998dae960d64a9db488336684f137a0")), TAS,
            address(bytes20(hex"4055530db392fb2b56037065a512c5b283d90a10")),
            address(bytes20(hex"51499a44bb7793647e67ed827bd17367d7e55314")),
            address(bytes20(hex"bcce994513615988690abca373b1368218e4957c")),
            address(bytes20(hex"fda72ce1d75b735d6595e5814ddf23b97516caef")),
            address(bytes20(hex"d1f8e787a325f91f5d4be2d30ea1e67b19e28b30")),
            address(bytes20(hex"4f11fb4c255d3edc7c44a461ab45fbc421aacb09")),
            address(bytes20(hex"636962584b1f492b06151fee87810281372879b6")),
            address(bytes20(hex"1121218d5e017b57c6df3b5a001a991bdb910338")),
            address(bytes20(hex"3f0f1551c7e08a2cf6800bd7d72abfe23e3e32a0")),
            address(bytes20(hex"3f22568ae0deaa24da7b8c669afdcbd72a6a7fd8")),
            address(bytes20(hex"26c32e54f23af9f9fcc757414c76e56e3fb176e2")),
            address(bytes20(hex"35077caf6fbef1d5677d318a198c9c47c61bb976")),
            address(bytes20(hex"7be6eaeb2fb5842da06a34af4fae418347427cd1")),
            address(bytes20(hex"35722eedf3f7566a23fa871f0a04267aee78e0db")),
            address(bytes20(hex"749f84ca070cd2f98d9353f49ece77c1a3fed532"))
        ];
        digest = keccak256(abi.encode(ITasGardenToken(GARDEN_TOKEN).ownerOf(2), TAS.codehash));
        for (uint256 i; i < gardens.length; ++i) {
            digest = keccak256(abi.encode(digest, gardens[i],
                ITasGardenToken(GARDEN_TOKEN).ownerOf(i), gardens[i].codehash, _hatConfig(gardens[i]),
                ITasJarRegistry(JAR_MODULE).getGardenJars(gardens[i]),
                ITasYieldResolver(RESOLVER).gardenTreasuries(gardens[i]),
                _vaultState(gardens[i], WETH), _vaultState(gardens[i], DAI)));
        }
        digest = keccak256(abi.encode(digest, IERC20(WETH).balanceOf(OLD_WETH_JAR),
            IERC20(DAI).balanceOf(OLD_DAI_JAR)));
    }

    function _hatConfig(address garden) private view returns (bytes32) {
        (bool success, bytes memory data) = HATS_MODULE.staticcall(abi.encodeCall(hatsModule.getGardenHatIds, (garden)));
        assertTrue(success);
        return keccak256(data);
    }

    function _vaultState(address garden, address asset) private view returns (bytes32) {
        address vault = ITasYieldResolver(RESOLVER).gardenVaults(garden, asset);
        if (vault == address(0)) return keccak256(abi.encode(address(0)));
        return keccak256(abi.encode(vault, ITasVault(vault).totalAssets(), ITasVault(vault).totalSupply()));
    }
}
