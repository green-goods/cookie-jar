// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {GardenCookieJar} from "../../src/GardenCookieJar.sol";
import {GardenCookieJarFactory} from "../../src/GardenCookieJarFactory.sol";
import {
    ITasMigrationOctant,
    ITasMigrationRegistry,
    ITasMigrationResolver,
    ITasMigrationToken
} from "./TasProductionRegistration.t.sol";

interface IFleetSafe {
    function nonce() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function approveHash(bytes32 hash) external;
    function getTransactionHash(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas,
        uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 nonce_
    ) external view returns (bytes32);
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas,
        uint256 baseGas, uint256 gasPrice, address gasToken, address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);
}

interface IFleetHats {
    function getGardenHatIds(address garden)
        external view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, bool);
}

interface IFleetHatWearers {
    function isWearerOfHat(address account, uint256 hat) external view returns (bool);
}

interface IFleetLegacyRetirement {
    function unlistOlderGardenJars(address[] calldata gardens) external;
}

contract GardenFleetSafeDryRunForkTest is Test {
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address private constant TOKEN = 0xe1Da335110b1ed48e7df63209f5D424d02276593;
    address private constant TAS = 0xA2DF8Eb73444A3f3cf9b8E3749313C7471d7D5E3;
    address private constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address private constant RELEASE_C = 0xD71adDC905a147320D82e934360b0e0C82dd76aF;
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    IFleetSafe private constant SAFE = IFleetSafe(0x1B9Ac97Ea62f69521A14cbe6F45eb24aD6612C19);
    ITasMigrationRegistry private constant REGISTRY = ITasMigrationRegistry(0x726bfbd0B7449C8f4aBfbcc2FBC5a89eB18fF157);
    ITasMigrationResolver private constant RESOLVER = ITasMigrationResolver(0x90896C86108528abB600Da3C48a1aa054958bDeb);
    ITasMigrationOctant private constant OCTANT = ITasMigrationOctant(0x70b25a2bAAA4f2Ae477bab315a87A03cfe89CEe9);
    IFleetHats private constant HATS_MODULE = IFleetHats(0x5b943088ecdDBF8E4ae387348A88A654aC5F7266);
    uint256 private constant ROWS = 18;
    uint256 private constant CALLS = 40;

    struct Pin {
        uint256 number;
        uint256 l1Block;
        uint256 timestamp;
        uint256 nonce;
        uint256 threshold;
    }

    struct Row {
        uint256 id;
        address garden;
        address treasury;
        uint256 ownerHat;
        uint256 stewardHat;
        uint256 gardenerHat;
        address weth;
        address dai;
    }

    struct Call {
        address to;
        bytes data;
        uint256 nonce;
        bytes32 hash;
        uint256 scheduleAt;
        uint256 executeAt;
    }

    struct RoleCandidates {
        uint256 id;
        address[] owners;
        address[] stewards;
    }

    struct FleetPacket {
        Pin pin;
        address safe;
        address registry;
        address manager;
        address deployer;
        bytes32 deployerCodeHash;
        address factory;
        address implementation;
        Row[] rows;
        Call[] calls;
    }

    function _readPacket() private view returns (FleetPacket memory) {
        return abi.decode(vm.parseBytes(vm.readFile(vm.envString("GARDEN_FLEET_PACKET"))), (FleetPacket));
    }
    address private signerA;
    address private signerB;

    function setUp() public {
        if (!vm.envOr("RUN_GARDEN_FLEET_SAFE_DRY_RUN", false)) {
            vm.skip(true);
            return;
        }
        FleetPacket memory p = _readPacket();
        vm.createSelectFork(vm.envString("TAS_HATS_RPC_URL"), p.pin.number);
        assertEq(vm.getChainId(), 42161);
        assertEq(vm.getBlockNumber(), p.pin.l1Block);
        assertEq(vm.getBlockTimestamp(), p.pin.timestamp);
        assertEq(address(SAFE), p.safe);
        assertEq(address(REGISTRY), p.registry);
        assertEq(REGISTRY.owner(), p.manager);
        assertEq(SAFE.nonce(), p.pin.nonce);
        assertEq(SAFE.getThreshold(), p.pin.threshold);
        assertEq(p.pin.threshold, 2);
        address[] memory owners = SAFE.getOwners();
        assertEq(owners.length, 5);
        (signerA, signerB) = owners[0] < owners[1] ? (owners[0], owners[1]) : (owners[1], owners[0]);
        assertEq(p.deployer.codehash, p.deployerCodeHash);
        assertEq(_implementation(), RELEASE_C);
    }

    function testIntegration_FleetExecutesExactUnsignedPacketAndDashboardReads() public {
        FleetPacket memory p = _readPacket();
        assertEq(p.rows.length, ROWS);
        assertEq(p.calls.length, CALLS);
        assertEq(p.factory.code.length, 0);
        assertEq(p.implementation.code.length, 0);
        address legacyFactory = REGISTRY.cookieJarFactory();
        uint256 assetThreshold = RESOLVER.assetYieldThresholds(WETH);
        uint256 globalThreshold = RESOLVER.minYieldThreshold();
        bytes32 beforeState = _fleetIdentity(p.rows, true);
        uint256 firstExecution = CALLS - ROWS;
        uint256 activationTime = p.calls[firstExecution].executeAt;
        assertGt(activationTime, 0);

        for (uint256 i; i < CALLS; ++i) {
            Call memory call = p.calls[i];
            if (call.scheduleAt != 0) vm.warp(call.scheduleAt);
            if (i >= firstExecution) {
                assertEq(call.executeAt, activationTime);
                if (i == firstExecution) {
                    vm.warp(call.executeAt - 1);
                    _execute(call, false);
                }
                vm.warp(call.executeAt);
            }
            _execute(call, true);
            if (i == firstExecution) {
                assertEq(_implementation(), p.implementation);
                assertEq(REGISTRY.getGardenJars(TAS).length, 2);
                for (uint256 row = 1; row < ROWS; ++row) {
                    assertEq(REGISTRY.getGardenJars(p.rows[row].garden).length, 0);
                }
            }
        }

        assertEq(REGISTRY.cookieJarFactory(), legacyFactory);
        assertEq(_implementation(), p.implementation);
        assertEq(_fleetIdentity(p.rows, false), beforeState);
        assertEq(RESOLVER.assetYieldThresholds(WETH), assetThreshold);
        assertEq(RESOLVER.minYieldThreshold(), globalThreshold);
        emit log_named_uint("Effective live WETH threshold", assetThreshold == 0 ? globalThreshold : assetThreshold);
        _verifyRegistrations(GardenCookieJarFactory(p.factory), p.rows);
        _dashboardReadback();
        address[] memory retired = new address[](1);
        retired[0] = TAS;
        vm.prank(p.manager);
        vm.expectRevert(abi.encodeWithSignature("ActiveHatsJar(address)", p.rows[0].weth));
        IFleetLegacyRetirement(address(REGISTRY)).unlistOlderGardenJars(retired);
        assertEq(REGISTRY.getGardenJars(TAS).length, 2);
        emit log_named_bytes32("Factory runtime code hash", p.factory.codehash);
        emit log_named_bytes32("Registry implementation runtime code hash", p.implementation.codehash);
        string memory roleFixture = vm.envOr("GARDEN_HATS_ACTORS", string(""));
        if (bytes(roleFixture).length != 0) {
            RoleCandidates[] memory candidates = abi.decode(vm.parseBytes(vm.readFile(roleFixture)), (RoleCandidates[]));
            _verifyTasPauseFallback(p.rows[0], candidates[0]);
            _verifyFleetAdministration(p.rows, candidates);
        }
    }

    function _verifyTasPauseFallback(Row memory tas, RoleCandidates memory candidates) private {
        assertEq(tas.garden, TAS);
        GardenCookieJar jar = GardenCookieJar(payable(tas.dai));
        IERC20Metadata token = IERC20Metadata(DAI);
        address vault = RESOLVER.gardenVaults(TAS, DAI);
        assertEq(RESOLVER.gardenTreasuries(TAS), tas.treasury);

        address owner = _owner(jar, candidates);
        vm.prank(owner);
        OCTANT.harvest(TAS, DAI);
        uint256 treasuryBefore = token.balanceOf(tas.treasury);
        uint256 beforeSplit = vm.snapshotState();
        RESOLVER.splitYield(TAS, DAI, vault);
        uint256 jarCredit = jar.currencyHeldByJar();
        uint256 treasuryIncrease = token.balanceOf(tas.treasury) - treasuryBefore;
        assertGt(jarCredit, 0, "live TAS DAI yield must credit an unpaused jar");
        assertTrue(vm.revertToState(beforeSplit));

        vm.prank(_operator(jar, candidates));
        jar.pause();
        RESOLVER.splitYield(TAS, DAI, vault);
        assertEq(token.balanceOf(tas.treasury) - treasuryBefore, treasuryIncrease + jarCredit);
        assertEq(jar.currencyHeldByJar(), 0);
        assertEq(token.balanceOf(address(jar)), 0);
        assertEq(token.allowance(address(RESOLVER), address(jar)), 0);
        vm.prank(owner);
        jar.unpause();
        emit log_named_uint("TAS paused jar yield routed to treasury", jarCredit);
    }

    function _verifyFleetAdministration(Row[] memory rows, RoleCandidates[] memory candidates) private {
        assertEq(candidates.length, ROWS);
        for (uint256 i; i < ROWS; ++i) {
            assertEq(rows[i].id, candidates[i].id);
            _proposeAndExerciseJar(GardenCookieJar(payable(rows[i].weth)), candidates[i]);
            _proposeAndExerciseJar(GardenCookieJar(payable(rows[i].dai)), candidates[i]);
        }
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        for (uint256 i; i < ROWS; ++i) {
            _applyJarPolicy(GardenCookieJar(payable(rows[i].weth)), candidates[i]);
            _applyJarPolicy(GardenCookieJar(payable(rows[i].dai)), candidates[i]);
        }
        emit log_named_uint("Jars with live Hats administration exercised", ROWS * 2);
    }

    function _owner(GardenCookieJar jar, RoleCandidates memory candidates) private view returns (address) {
        for (uint256 i; i < candidates.owners.length; ++i) {
            if (jar.isOwner(candidates.owners[i])) return candidates.owners[i];
        }
        revert("No active Owner Hat wearer");
    }

    function _operator(GardenCookieJar jar, RoleCandidates memory candidates) private view returns (address) {
        address dualWearer;
        for (uint256 i; i < candidates.stewards.length; ++i) {
            address candidate = candidates.stewards[i];
            if (!IFleetHatWearers(jar.HATS()).isWearerOfHat(candidate, jar.STEWARD_HAT())) continue;
            if (!jar.isOperator(candidate)) continue;
            if (!jar.isOwner(candidate)) return candidate;
            dualWearer = candidate;
        }
        require(dualWearer != address(0), "No active Steward Hat wearer");
        return dualWearer;
    }

    function _proposeAndExerciseJar(GardenCookieJar jar, RoleCandidates memory candidates) private {
        address owner = _owner(jar, candidates);
        address steward = _operator(jar, candidates);
        address nonOwner = jar.isOwner(steward) ? jar.GARDEN() : steward;
        if (nonOwner != steward) emit log_named_address("Jar with only dual-role stewards", address(jar));
        (uint256 ceiling, uint256 cooldown, uint256 budget, address recipient) = jar.policy();
        GardenCookieJar.Policy memory next = GardenCookieJar.Policy(ceiling, cooldown, budget + 1, recipient);

        vm.prank(jar.GARDEN());
        vm.expectRevert(GardenCookieJar.NotOperator.selector);
        jar.pause();
        vm.prank(nonOwner);
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.proposePolicy(next);
        vm.prank(steward);
        jar.setOperationalLimits(ceiling, cooldown);
        assertEq(jar.maxWithdrawal(), ceiling);

        IERC20Metadata token = IERC20Metadata(jar.CURRENCY());
        deal(address(token), owner, 2);
        vm.startPrank(owner);
        token.approve(address(jar), 1);
        jar.deposit(1);
        token.transfer(address(jar), 1);
        vm.stopPrank();

        vm.prank(steward);
        jar.pause();
        assertTrue(jar.paused());
        vm.prank(nonOwner);
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.unpause();
        vm.prank(nonOwner);
        vm.expectRevert(GardenCookieJar.NotOwner.selector);
        jar.emergencyWithdraw(1);

        uint256 recipientBalance = token.balanceOf(recipient);
        vm.startPrank(owner);
        jar.emergencyWithdraw(1);
        jar.recoverSurplus(address(token), 1);
        jar.unpause();
        jar.proposePolicy(next);
        bytes32 expected = keccak256(abi.encode(next));
        assertEq(jar.pendingPolicyHash(), expected);
        vm.expectRevert(abi.encodeWithSelector(GardenCookieJar.PolicyNotReady.selector, block.timestamp + 48 hours));
        jar.executePolicy(expected);
        vm.stopPrank();
        assertEq(token.balanceOf(recipient), recipientBalance + 2);
        assertEq(jar.currencyHeldByJar(), 0);
    }

    function _applyJarPolicy(GardenCookieJar jar, RoleCandidates memory candidates) private {
        address owner = _owner(jar, candidates);
        bytes32 expected = jar.pendingPolicyHash();
        (,, uint256 budget,) = jar.pendingPolicy();
        vm.prank(owner);
        jar.executePolicy(expected);
        (,, uint256 activeBudget,) = jar.policy();
        assertEq(activeBudget, budget);
        assertEq(jar.pendingPolicyHash(), bytes32(0));
    }

    function _execute(Call memory call, bool succeeds) private {
        assertEq(SAFE.nonce(), call.nonce);
        assertEq(
            SAFE.getTransactionHash(call.to, 0, call.data, 0, 0, 0, 0, address(0), address(0), call.nonce),
            call.hash
        );
        vm.prank(signerA);
        SAFE.approveHash(call.hash);
        vm.prank(signerB);
        SAFE.approveHash(call.hash);
        bytes memory signatures = abi.encodePacked(
            bytes32(uint256(uint160(signerA))), bytes32(0), uint8(1),
            bytes32(uint256(uint160(signerB))), bytes32(0), uint8(1)
        );
        if (!succeeds) vm.expectRevert();
        uint256 gasBefore = gasleft();
        bool success = SAFE.execTransaction(
            call.to, 0, call.data, 0, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        if (succeeds) {
            assertTrue(success);
            assertEq(SAFE.nonce(), call.nonce + 1);
            emit log_named_uint(string.concat("Gas Safe nonce ", vm.toString(call.nonce)), gasBefore - gasleft());
        } else {
            assertEq(SAFE.nonce(), call.nonce);
        }
    }

    function _fleetIdentity(Row[] memory rows, bool requireEmpty) private view returns (bytes32 digest) {
        for (uint256 i; i < ROWS; ++i) {
            Row memory row = rows[i];
            address garden = row.garden;
            assertTrue(ITasMigrationToken(TOKEN).isGardenAccount(garden));
            address treasury = RESOLVER.gardenTreasuries(garden);
            assertEq(treasury, row.treasury);
            if (requireEmpty) {
                assertEq(REGISTRY.getGardenJars(garden).length, 0);
                assertEq(REGISTRY.getGardenJar(garden, WETH), address(0));
                assertEq(REGISTRY.getGardenJar(garden, DAI), address(0));
            }
            (uint256 owner, uint256 steward, uint256 evaluator, uint256 gardener, uint256 funder, uint256 community,
                uint256 admin, bool configured) = HATS_MODULE.getGardenHatIds(garden);
            assertTrue(configured);
            assertEq(owner, row.ownerHat);
            assertEq(steward, row.stewardHat);
            assertEq(gardener, row.gardenerHat);
            digest = keccak256(abi.encode(
                digest, garden, garden.codehash, ITasMigrationToken(TOKEN).ownerOf(row.id), owner, steward, evaluator,
                gardener, funder, community, admin, treasury, RESOLVER.gardenVaults(garden, WETH),
                RESOLVER.gardenVaults(garden, DAI)
            ));
        }
    }

    function _verifyRegistrations(GardenCookieJarFactory factory, Row[] memory rows) private view {
        assertEq(factory.registrar(), address(REGISTRY));
        assertEq(factory.GOVERNANCE(), address(SAFE));
        assertEq(factory.HATS(), HATS);
        address[] memory unique = new address[](2 * ROWS);
        for (uint256 i; i < ROWS; ++i) {
            Row memory row = rows[i];
            address garden = row.garden;
            address[] memory listed = REGISTRY.getGardenJars(garden);
            assertEq(listed.length, 2);
            for (uint256 j; j < 2; ++j) {
                address asset = j == 0 ? WETH : DAI;
                address jar = listed[j];
                assertEq(jar, j == 0 ? row.weth : row.dai);
                assertEq(REGISTRY.getGardenJar(garden, asset), jar);
                assertEq(factory.jarFor(garden, asset, 1), jar);
                assertTrue(factory.isFactoryJar(jar));
                assertEq(GardenCookieJar(jar).CURRENCY(), asset);
                assertEq(GardenCookieJar(jar).GARDEN(), garden);
                assertEq(GardenCookieJar(jar).GARDENER_HAT(), row.gardenerHat);
                assertEq(GardenCookieJar(jar).currencyHeldByJar(), 0);
                for (uint256 prior; prior < 2 * i + j; ++prior) assertTrue(unique[prior] != jar);
                unique[2 * i + j] = jar;
            }
        }
    }

    function _dashboardReadback() private {
        address[] memory addresses = REGISTRY.getGardenJars(TAS);
        emit log_named_bytes("Dashboard registry result", abi.encode(addresses));
        for (uint256 i; i < addresses.length; ++i) {
            GardenCookieJar jar = GardenCookieJar(addresses[i]);
            address asset = jar.CURRENCY();
            uint8 decimals = IERC20Metadata(asset).decimals();
            assertEq(decimals, 18);
            assertEq(jar.currencyHeldByJar(), 0);
            assertEq(jar.maxWithdrawal(), i == 0 ? 0.01 ether : 10 ether);
            assertEq(jar.withdrawalInterval(), 1 days);
            assertFalse(jar.paused());
            assertTrue(jar.EMERGENCY_WITHDRAWAL_ENABLED());
            assertEq(jar.MIN_DEPOSIT(), 0);
            emit log_named_bytes(
                i == 0 ? "Dashboard WETH result" : "Dashboard DAI result",
                abi.encode(address(jar), asset, jar.currencyHeldByJar(), jar.maxWithdrawal(), jar.withdrawalInterval(),
                    jar.paused(), jar.EMERGENCY_WITHDRAWAL_ENABLED(), jar.MIN_DEPOSIT(), decimals)
            );
        }
    }

    function _implementation() private view returns (address) {
        return address(uint160(uint256(vm.load(address(REGISTRY), IMPLEMENTATION_SLOT))));
    }
}
