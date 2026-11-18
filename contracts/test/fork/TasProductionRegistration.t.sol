// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GardenCookieJar} from "../../src/GardenCookieJar.sol";
import {GardenCookieJarFactory} from "../../src/GardenCookieJarFactory.sol";

interface ITasMigrationManager {
    function canCall(address caller, address target, bytes4 selector) external view returns (bool, uint32);
    function schedule(address target, bytes calldata data, uint48 when) external returns (bytes32, uint32);
    function execute(address target, bytes calldata data) external payable returns (uint32);
}

interface ITasMigrationRegistry {
    function owner() external view returns (address);
    function cookieJarFactory() external view returns (address);
    function getGardenJar(address garden, address asset) external view returns (address);
    function getGardenJars(address garden) external view returns (address[] memory);
    function upgradeToAndCall(address implementation, bytes calldata data) external payable;
    function provisionHatsJarPair(
        GardenCookieJar.Config calldata first, GardenCookieJar.Config calldata second, uint256 generation
    ) external returns (address, address);
}

interface ITasMigrationToken {
    function isGardenAccount(address garden) external view returns (bool);
    function ownerOf(uint256 id) external view returns (address);
}

interface ITasMigrationAccounts {
    function account(address implementation, bytes32 salt, uint256 chain, address token, uint256 id)
        external view returns (address);
}

interface ITasMigrationOctant {
    function harvest(address garden, address asset) external;
    function getVaultForAsset(address garden, address asset) external view returns (address);
}

interface ITasMigrationVault is IERC20 {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

interface ITasMigrationResolver {
    function gardenShares(address garden, address vault) external view returns (uint256);
    function totalRegisteredShares(address vault) external view returns (uint256);
    function pendingYield(address garden, address asset) external view returns (uint256);
    function escrowedFractions(address garden, address asset) external view returns (uint256);
    function gardenTreasuries(address garden) external view returns (address);
    function gardenVaults(address garden, address asset) external view returns (address);
    function splitYield(address garden, address asset, address vault) external;
    function setAssetYieldThreshold(address asset, uint256 threshold) external;
    function assetYieldThresholds(address asset) external view returns (uint256);
    function minYieldThreshold() external view returns (uint256);
}

contract TasProductionRegistrationForkTest is Test {
    error MissingYieldSplit();

    uint256 private constant FORK_BLOCK = 522_211_968;
    uint256 private constant OWNER_HAT = 0x0000005c00020001000300010000000000000000000000000000000000000000;
    uint256 private constant STEWARD_HAT = 0x0000005c00020001000300020000000000000000000000000000000000000000;
    uint256 private constant GARDENER_HAT = 0x0000005c00020001000300040000000000000000000000000000000000000000;
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant YIELD_SPLIT =
        keccak256("YieldSplit(address,address,uint256,uint256,uint256,uint256)");

    address private constant TAS = 0xA2DF8Eb73444A3f3cf9b8E3749313C7471d7D5E3;
    address private constant HATS = 0x3bc1A0Ad72417f2d411118085256fC53CBdDd137;
    address private constant HATS_MODULE = 0x5b943088ecdDBF8E4ae387348A88A654aC5F7266;
    address private constant TOKEN = 0xe1Da335110b1ed48e7df63209f5D424d02276593;
    address private constant SAFE = 0x1B9Ac97Ea62f69521A14cbe6F45eb24aD6612C19;
    address private constant TAS_OWNER = 0x6855B23D93f57851d30a324B00f17f9baf34Ac02;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address private constant WETH_VAULT = 0x78AfBa2d6d2CAD94776803AFbb53B0B8105fFE51;
    address private constant DAI_VAULT = 0xe38e6f8e544F2E86dE01d6f3bC1482e26b15f117;
    address private constant OLD_WETH_JAR = 0x69C56D8f7b6c7feaA9Bf2D91285ED2b141B84cCa;
    address private constant OLD_DAI_JAR = 0x91cDcD4B620d82cCC97EC5aE7Ee7B4b833d16021;
    address private constant RELEASE_C = 0xD71adDC905a147320D82e934360b0e0C82dd76aF;
    address private constant LEGACY_ACCOUNT = 0xE31cAeAc029A60AD17A49278Fdd58032eF9Cf692;
    address private constant TBA_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    bytes32 private constant TBA_SALT =
        0x6551655165516551655165516551655165516551655165516551655165516551;

    ITasMigrationRegistry private constant REGISTRY = ITasMigrationRegistry(0x726bfbd0B7449C8f4aBfbcc2FBC5a89eB18fF157);
    ITasMigrationManager private constant MANAGER = ITasMigrationManager(0xfBf07b2d0e5eA8249756F205e5214B9d7cDF4e66);
    ITasMigrationOctant private constant OCTANT = ITasMigrationOctant(0x70b25a2bAAA4f2Ae477bab315a87A03cfe89CEe9);
    ITasMigrationResolver private constant RESOLVER = ITasMigrationResolver(0x90896C86108528abB600Da3C48a1aa054958bDeb);

    struct YieldSnapshot {
        uint256 pending;
        uint256 escrow;
        uint256 balance;
        uint256 shares;
        uint256 aggregateShares;
    }

    struct PrincipalSnapshot {
        uint256 shares;
        uint256 assets;
    }

    function setUp() public {
        if (!vm.envOr("RUN_TAS_PRODUCTION_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envString("TAS_HATS_RPC_URL"), FORK_BLOCK);
        assertEq(vm.getChainId(), 42_161);
        assertEq(vm.getBlockNumber(), 26_366_125);
        assertEq(vm.getBlockTimestamp(), 1_794_092_427);
        assertEq(_implementation(), RELEASE_C);
        assertEq(REGISTRY.owner(), address(MANAGER));
        assertEq(OCTANT.getVaultForAsset(TAS, WETH), WETH_VAULT);
        assertEq(OCTANT.getVaultForAsset(TAS, DAI), DAI_VAULT);
    }

    function testIntegration_TasAtomicRegistrationAndLiveHarvestPayout() public {
        (GardenCookieJar wethJar, GardenCookieJar daiJar) = _activatePair();
        bytes32 preserved = _fleetState();

        _harvest(DAI, DAI_VAULT);
        _splitAndClaim(DAI, DAI_VAULT, daiJar);
        assertEq(_fleetState(), preserved);

        _harvest(WETH, WETH_VAULT);
        PrincipalSnapshot memory wethPrincipal = _principal(WETH_VAULT);
        RESOLVER.splitYield(TAS, WETH, WETH_VAULT);
        _assertPrincipal(WETH_VAULT, wethPrincipal);
        uint256 pending = RESOLVER.pendingYield(TAS, WETH);
        assertGt(pending, 0, "real WETH yield must remain pending");
        assertLt(pending, RESOLVER.minYieldThreshold());
        assertEq(wethJar.currencyHeldByJar(), 0);
        assertEq(_fleetState(), preserved);
        emit log_named_uint("WETH pending under live threshold", pending);

        // Demonstrate payout with a fork-only asset threshold through the same governance route.
        // The production WETH threshold requires a separate economic decision and approval.
        bytes memory threshold = abi.encodeCall(RESOLVER.setAssetYieldThreshold, (WETH, 1));
        _mature(address(RESOLVER), threshold);
        vm.prank(SAFE);
        MANAGER.execute(address(RESOLVER), threshold);
        assertEq(RESOLVER.assetYieldThresholds(WETH), 1);
        preserved = _fleetState();
        _splitAndClaim(WETH, WETH_VAULT, wethJar);
        assertEq(_fleetState(), preserved);
    }

    function _activatePair() private returns (GardenCookieJar wethJar, GardenCookieJar daiJar) {
        address legacyFactory = REGISTRY.cookieJarFactory();
        GardenCookieJarFactory factory = new GardenCookieJarFactory(SAFE, address(REGISTRY), HATS);
        vm.prank(SAFE);
        factory.setAssetAdmission(WETH, 18, true);

        bytes memory initCode = abi.encodePacked(vm.envBytes("TAS_REGISTRY_INIT_CODE"), abi.encode(address(factory)));
        address implementation;
        assembly ("memory-safe") {
            implementation := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertGt(implementation.code.length, 0, "compiled module deployment");
        bytes memory pair = abi.encodeCall(REGISTRY.provisionHatsJarPair, (_config(WETH), _config(DAI), 1));
        bytes memory upgrade = abi.encodeCall(REGISTRY.upgradeToAndCall, (implementation, pair));

        _mature(address(REGISTRY), upgrade);
        bytes32 preserved = _fleetState();
        assertEq(REGISTRY.getGardenJars(TAS).length, 0);

        // The second asset is not admitted. The Safe's scheduled atomic upgrade must roll back,
        // including the first CREATE2 deployment and the consumed AccessManager schedule.
        vm.expectRevert(GardenCookieJarFactory.AssetNotAdmitted.selector);
        vm.prank(SAFE);
        MANAGER.execute(address(REGISTRY), upgrade);
        assertEq(_implementation(), RELEASE_C);
        assertEq(factory.jarFor(TAS, WETH, 1), address(0));
        assertEq(REGISTRY.getGardenJars(TAS).length, 0);

        vm.prank(SAFE);
        factory.setAssetAdmission(DAI, 18, true);
        vm.prank(SAFE);
        MANAGER.execute(address(REGISTRY), upgrade);
        assertEq(_implementation(), implementation);
        assertEq(REGISTRY.cookieJarFactory(), legacyFactory);
        assertEq(REGISTRY.owner(), address(MANAGER));
        assertEq(_fleetState(), preserved);

        address[] memory listed = REGISTRY.getGardenJars(TAS);
        assertEq(listed.length, 2);
        assertEq(listed[0], REGISTRY.getGardenJar(TAS, WETH));
        assertEq(listed[1], REGISTRY.getGardenJar(TAS, DAI));
        assertEq(listed[0], factory.jarFor(TAS, WETH, 1));
        assertEq(listed[1], factory.jarFor(TAS, DAI, 1));
        wethJar = GardenCookieJar(listed[0]);
        daiJar = GardenCookieJar(listed[1]);
        assertEq(wethJar.GARDENER_HAT(), GARDENER_HAT);
        assertEq(daiJar.GARDENER_HAT(), GARDENER_HAT);

        vm.expectRevert();
        vm.prank(SAFE);
        MANAGER.execute(address(REGISTRY), upgrade);
        vm.expectRevert();
        REGISTRY.provisionHatsJarPair(_config(WETH), _config(DAI), 2);
        vm.expectRevert();
        vm.prank(address(MANAGER));
        REGISTRY.provisionHatsJarPair(_config(WETH), _config(DAI), 2);
        emit log_named_address("Fork registry implementation", implementation);
        emit log_named_address("Fork factory", address(factory));
        emit log_named_address("Fork WETH jar", listed[0]);
        emit log_named_address("Fork DAI jar", listed[1]);
    }

    function _mature(address target, bytes memory data) private {
        (bool immediate, uint32 delay) = MANAGER.canCall(SAFE, target, bytes4(data));
        assertFalse(immediate);
        assertEq(delay, 1 days);
        uint48 readyAt = uint48(vm.getBlockTimestamp() + delay);
        vm.prank(SAFE);
        MANAGER.schedule(target, data, readyAt);
        vm.expectRevert();
        vm.prank(SAFE);
        MANAGER.execute(target, data);
        vm.warp(readyAt);
    }

    function _harvest(address asset, address vault) private {
        PrincipalSnapshot memory principal = _principal(vault);
        uint256 sharesBefore = RESOLVER.gardenShares(TAS, vault);
        uint256 resolverSharesBefore = IERC20(vault).balanceOf(address(RESOLVER));
        uint256 aggregateBefore = RESOLVER.totalRegisteredShares(vault);
        vm.prank(TAS_OWNER);
        OCTANT.harvest(TAS, asset);
        uint256 registered = RESOLVER.gardenShares(TAS, vault) - sharesBefore;
        assertGt(registered, 0, "live vault report must mint new yield shares");
        assertEq(IERC20(vault).balanceOf(address(RESOLVER)) - resolverSharesBefore, registered);
        assertEq(RESOLVER.totalRegisteredShares(vault) - aggregateBefore, registered);
        _assertPrincipal(vault, principal);
        emit log_named_uint("Existing registered shares", sharesBefore);
        emit log_named_uint("Newly harvested registered shares", registered);
    }

    function _splitAndClaim(address asset, address vault, GardenCookieJar jar) private {
        PrincipalSnapshot memory principal = _principal(vault);
        YieldSnapshot memory before = YieldSnapshot({
            pending: RESOLVER.pendingYield(TAS, asset),
            escrow: RESOLVER.escrowedFractions(TAS, asset),
            balance: IERC20(asset).balanceOf(address(RESOLVER)),
            shares: RESOLVER.gardenShares(TAS, vault),
            aggregateShares: RESOLVER.totalRegisteredShares(vault)
        });
        assertEq(jar.currencyHeldByJar(), 0);
        vm.recordLogs();
        RESOLVER.splitYield(TAS, asset, vault);
        (uint256 credited, uint256 fractions, uint256 remainder, uint256 total) = _splitEvent(asset);
        assertGt(credited, 0, "split must credit the registered jar");
        assertEq(credited, total * 4865 / 10_000);
        assertEq(fractions, total * 4865 / 10_000);
        assertEq(credited + fractions + remainder, total);
        assertEq(RESOLVER.pendingYield(TAS, asset), 0);
        uint256 sharesSpent = before.shares - RESOLVER.gardenShares(TAS, vault);
        assertEq(before.aggregateShares - RESOLVER.totalRegisteredShares(vault), sharesSpent);
        if (before.pending == 0) assertGt(sharesSpent, 0, "live vault shares must redeem");
        uint256 newEscrow = RESOLVER.escrowedFractions(TAS, asset) - before.escrow;
        assertEq(IERC20(asset).balanceOf(address(RESOLVER)) + before.pending, before.balance + newEscrow);
        assertEq(IERC20(asset).allowance(address(RESOLVER), address(jar)), 0);
        assertEq(jar.currencyHeldByJar(), credited);
        assertEq(IERC20(asset).balanceOf(address(jar)), credited);

        uint256 amount = credited < jar.maxWithdrawal() ? credited : jar.maxWithdrawal();
        uint256 balanceBefore = IERC20(asset).balanceOf(TAS_OWNER);
        vm.prank(TAS_OWNER);
        jar.withdraw(amount, "Fork-only payout from TAS vault yield");
        assertEq(IERC20(asset).balanceOf(TAS_OWNER) - balanceBefore, amount);
        assertEq(jar.currencyHeldByJar(), credited - amount);
        assertEq(IERC20(asset).balanceOf(address(jar)), credited - amount);
        _assertPrincipal(vault, principal);
        emit log_named_address("Yield asset", asset);
        emit log_named_uint("Total split yield", total);
        emit log_named_uint("Credited jar", credited);
        emit log_named_uint("Gardener payout", amount);
    }

    function _principal(address vault) private view returns (PrincipalSnapshot memory snapshot) {
        ITasMigrationVault token = ITasMigrationVault(vault);
        snapshot.shares = token.totalSupply() - token.balanceOf(address(RESOLVER));
        snapshot.assets = token.convertToAssets(snapshot.shares);
    }

    function _assertPrincipal(address vault, PrincipalSnapshot memory before) private view {
        PrincipalSnapshot memory afterOperation = _principal(vault);
        assertEq(afterOperation.shares, before.shares, "non-resolver vault shares changed");
        assertGe(afterOperation.assets + 1, before.assets, "non-resolver vault value fell");
    }

    function _splitEvent(address asset) private view returns (uint256, uint256, uint256, uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(RESOLVER) || entry.topics.length != 3 || entry.topics[0] != YIELD_SPLIT) {
                continue;
            }
            assertEq(address(uint160(uint256(entry.topics[1]))), TAS);
            assertEq(address(uint160(uint256(entry.topics[2]))), asset);
            return abi.decode(entry.data, (uint256, uint256, uint256, uint256));
        }
        revert MissingYieldSplit();
    }

    function _fleetState() private view returns (bytes32 digest) {
        for (uint256 id; id < 18; ++id) {
            address garden = ITasMigrationAccounts(TBA_REGISTRY).account(LEGACY_ACCOUNT, TBA_SALT, 42_161, TOKEN, id);
            assertTrue(ITasMigrationToken(TOKEN).isGardenAccount(garden));
            if (id == 2) assertEq(garden, TAS);
            (bool ok, bytes memory hats) = HATS_MODULE.staticcall(abi.encodeWithSignature("getGardenHatIds(address)", garden));
            assertTrue(ok);
            digest = keccak256(abi.encode(
                digest, garden, garden.codehash, ITasMigrationToken(TOKEN).ownerOf(id), hats,
                RESOLVER.gardenTreasuries(garden), _vaultState(garden, WETH), _vaultState(garden, DAI)
            ));
            if (garden != TAS) digest = keccak256(abi.encode(digest, REGISTRY.getGardenJars(garden)));
        }
        digest = keccak256(abi.encode(digest, IERC20(WETH).balanceOf(OLD_WETH_JAR), IERC20(DAI).balanceOf(OLD_DAI_JAR)));
    }

    function _vaultState(address garden, address asset) private view returns (bytes32) {
        address vault = RESOLVER.gardenVaults(garden, asset);
        if (garden == TAS) return keccak256(abi.encode(vault));
        return keccak256(abi.encode(
            vault, RESOLVER.gardenShares(garden, vault), RESOLVER.pendingYield(garden, asset),
            REGISTRY.getGardenJar(garden, asset), vault == address(0) ? 0 : IERC20(vault).totalSupply(),
            vault == address(0) ? 0 : ITasMigrationVault(vault).totalAssets()
        ));
    }

    function _implementation() private view returns (address) {
        return address(uint160(uint256(vm.load(address(REGISTRY), IMPLEMENTATION_SLOT))));
    }

    function _config(address asset) private pure returns (GardenCookieJar.Config memory) {
        bool weth = asset == WETH;
        return GardenCookieJar.Config({
            garden: TAS,
            asset: asset,
            hats: HATS,
            gardenerHat: GARDENER_HAT,
            stewardHat: STEWARD_HAT,
            ownerHat: OWNER_HAT,
            policy: GardenCookieJar.Policy(weth ? 0.02 ether : 20 ether, 1 days, weth ? 0.1 ether : 100 ether, SAFE),
            maxWithdrawal: weth ? 0.01 ether : 10 ether,
            withdrawalInterval: 1 days
        });
    }
}
