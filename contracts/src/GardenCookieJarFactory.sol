// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {GardenCookieJar} from "./GardenCookieJar.sol";

/// @title GardenCookieJarFactory
/// @notice Deploys versioned, single-asset jars with direct Hats administration.
/// @dev Admission and deployment authority confer no authority over an existing jar's funds.
contract GardenCookieJarFactory {
    struct AssetAdmission {
        uint8 decimals;
        bool enabled;
    }

    uint256 public constant VERSION = 1;
    bytes32 public constant FAMILY = keccak256("GREEN_GOODS_GARDEN_COOKIE_JAR_FACTORY");
    address public immutable GOVERNANCE;
    address public immutable HATS;
    address public registrar;
    bool public creationPaused;
    mapping(address => AssetAdmission) public assetAdmission;
    mapping(address => mapping(address => mapping(uint256 => address))) public jarFor;
    mapping(address => bool) public isFactoryJar;

    event RegistrarChanged(address indexed previousRegistrar, address indexed registrar);
    event AssetAdmissionChanged(address indexed asset, uint8 decimals, bool enabled);
    event CreationPauseChanged(bool paused);
    event JarCreated(
        address indexed garden,
        address indexed asset,
        address indexed jar,
        uint256 generation,
        address registrar,
        bytes32 configHash
    );

    error NotGovernance();
    error NotRegistrar();
    error InvalidConfiguration();
    error CreationPaused();
    error AssetNotAdmitted();
    error TokenDecimalsChanged();
    error JarAlreadyExists();

    modifier onlyGovernance() {
        if (msg.sender != GOVERNANCE) revert NotGovernance();
        _;
    }

    constructor(address governance, address registrar_, address hats) {
        if (governance == address(0) || registrar_ == address(0) || hats.code.length == 0) {
            revert InvalidConfiguration();
        }
        GOVERNANCE = governance;
        HATS = hats;
        registrar = registrar_;
        emit RegistrarChanged(address(0), registrar_);
    }

    /// @notice Choose the registrar used for future deployments without affecting existing jars.
    function setRegistrar(address nextRegistrar) external onlyGovernance {
        if (nextRegistrar == address(0)) revert InvalidConfiguration();
        address previous = registrar;
        registrar = nextRegistrar;
        emit RegistrarChanged(previous, nextRegistrar);
    }

    /// @notice Admit a reviewed asset with explicit decimals, or stop new jars for that asset.
    function setAssetAdmission(address asset, uint8 decimals_, bool enabled) external onlyGovernance {
        if (asset.code.length == 0) revert InvalidConfiguration();
        if (enabled && IERC20Metadata(asset).decimals() != decimals_) revert TokenDecimalsChanged();
        assetAdmission[asset] = AssetAdmission(decimals_, enabled);
        emit AssetAdmissionChanged(asset, decimals_, enabled);
    }

    /// @notice Pause creation only; claims and administration of deployed jars remain local to each jar.
    function setCreationPaused(bool paused_) external onlyGovernance {
        creationPaused = paused_;
        emit CreationPauseChanged(paused_);
    }

    /// @notice Deploy exactly one jar for a garden/asset/generation and record its immutable provenance.
    /// @dev The registrar must separately validate canonical garden identity and role IDs before registration.
    function createJar(GardenCookieJar.Config calldata config, uint256 generation) external returns (address jar) {
        if (msg.sender != registrar) revert NotRegistrar();
        if (creationPaused) revert CreationPaused();
        if (config.hats != HATS || generation == 0) revert InvalidConfiguration();
        AssetAdmission memory admission = assetAdmission[config.asset];
        if (!admission.enabled) revert AssetNotAdmitted();
        if (IERC20Metadata(config.asset).decimals() != admission.decimals) revert TokenDecimalsChanged();
        if (jarFor[config.garden][config.asset][generation] != address(0)) revert JarAlreadyExists();
        jar = address(new GardenCookieJar{salt: _salt(config, generation)}(config));
        jarFor[config.garden][config.asset][generation] = jar;
        isFactoryJar[jar] = true;
        emit JarCreated(config.garden, config.asset, jar, generation, msg.sender, keccak256(abi.encode(config)));
    }

    /// @notice Predict the address using the current registrar and every constructor input.
    function predictJarAddress(GardenCookieJar.Config calldata config, uint256 generation) external view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(GardenCookieJar).creationCode, abi.encode(config)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(config, generation), initCodeHash)))));
    }

    function _salt(GardenCookieJar.Config calldata config, uint256 generation) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, registrar, config.garden, config.asset, generation, keccak256(abi.encode(config))));
    }
}
