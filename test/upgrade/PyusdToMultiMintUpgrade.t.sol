// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import {Test} from "forge-std/Test.sol";

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {USDai} from "src/USDai.sol";
import {IUSDai} from "src/interfaces/IUSDai.sol";
import {ISwapAdapter} from "src/interfaces/ISwapAdapter.sol";

/*------------------------------------------------------------------------*/
/* Local interfaces for PYUSDX suite (0.8.34, cannot import directly)    */
/*------------------------------------------------------------------------*/

interface IPYUSDX {
    struct InitializeParams {
        string name;
        string symbol;
        address admin;
        address pauser;
        address freezeManager;
        address forcedTransferManager;
        address earnerManager;
        address rateLimitManager;
        address issuer;
    }
    function initialize(
        InitializeParams calldata params
    ) external;
    function setAccountInfo(
        address account,
        uint32 earnerRate,
        uint16 feeRate,
        address claimRecipient
    ) external;
}

interface IIssuerGateway {
    function initialize(
        address admin,
        address operator,
        address executor,
        uint32 mintDelay,
        uint32 mintTTL
    ) external;
}

interface ISwapFacilityInit {
    function initialize(
        address admin,
        address pauser
    ) external;
}

interface IExtensionBeaconInit {
    function initialize(
        address admin,
        address beaconManager,
        address yieldToOneImpl,
        address multiMintImpl
    ) external;
}

interface IExtensionFactoryInit {
    function initialize(
        address admin,
        address factoryManager
    ) external;
    function setExtensionType(
        address extension,
        uint8 extensionType
    ) external;
}

interface IMultiMintInit {
    function initialize(
        string memory name,
        string memory symbol,
        address yieldRecipient,
        address admin,
        address assetCapManager,
        address freezeManager,
        address pauser,
        address yieldRecipientManager,
        address versionManager
    ) external;
    function setAssetCap(
        address asset,
        uint256 cap
    ) external;
}

/**
 * @notice Minimal ISwapAdapter mock that returns a configurable baseToken address.
 *         All swap functions revert — only `baseToken()` is needed for USDai constructor.
 */
contract SwapAdapterMock is ISwapAdapter {
    address private immutable _baseToken;

    constructor(
        address baseToken_
    ) {
        _baseToken = baseToken_;
    }

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    function swapIn(
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (uint256) {
        revert("SwapAdapterMock: not implemented");
    }

    function swapOut(
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (uint256) {
        revert("SwapAdapterMock: not implemented");
    }
}

/**
 * @title PYUSD → MultiMint upgrade test
 * @author MetaStreet Foundation
 * @dev Fork-based test verifying atomic PYUSD→MultiMint migration.
 *      Requires ARBITRUM_RPC_URL env var.
 *      Forks at block 424398311 (pre-upgrade).
 *      Deploys a fresh PYUSDX suite from pre-compiled 0.8.34 artifacts.
 */
contract PyusdToMultiMintUpgradeTest is Test {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    address internal constant PYUSD = 0x46850aD61C2B7d64d08c9C754F45254596696984;
    address internal constant USDAI_PROXY = 0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF;
    address internal constant STAKED_USDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;

    /*------------------------------------------------------------------------*/
    /* Artifact paths (pre-compiled 0.8.34 in lib/pyusdx/out/) */
    /*------------------------------------------------------------------------*/

    string internal constant ART_PYUSDX = "lib/pyusdx/out/PYUSDX.sol/PYUSDX.json";
    string internal constant ART_ISSUER_GATEWAY = "lib/pyusdx/out/IssuerGateway.sol/IssuerGateway.json";
    string internal constant ART_SWAP_FACILITY = "lib/pyusdx/out/SwapFacility.sol/SwapFacility.json";
    string internal constant ART_YIELD_TO_ONE = "lib/pyusdx/out/YieldToOne.sol/YieldToOne.json";
    string internal constant ART_MULTI_MINT = "lib/pyusdx/out/MultiMint.sol/MultiMint.json";
    string internal constant ART_BEACON = "lib/pyusdx/out/ExtensionBeacon.sol/ExtensionBeacon.json";
    string internal constant ART_FACTORY = "lib/pyusdx/out/ExtensionFactory.sol/ExtensionFactory.json";
    string internal constant ART_TUP =
        "lib/pyusdx/out/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json";
    string internal constant ART_BEACON_PROXY = "lib/pyusdx/out/ExtensionBeaconProxy.sol/ExtensionBeaconProxy.json";

    /*------------------------------------------------------------------------*/
    /* Freshly deployed PYUSDX suite */
    /*------------------------------------------------------------------------*/

    address internal pyusdxProxy;
    address internal swapFacilityProxy;
    address internal multiMintProxy;
    address internal swapAdapter;

    /*------------------------------------------------------------------------*/
    /* State */
    /*------------------------------------------------------------------------*/

    ProxyAdmin internal proxyAdmin;
    address internal proxyAdminOwner;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));
        vm.rollFork(455_362_575);

        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(USDAI_PROXY, ERC1967Utils.ADMIN_SLOT)))));
        proxyAdminOwner = proxyAdmin.owner();

        _deployPyusdxSuite();
    }

    /*------------------------------------------------------------------------*/
    /* PYUSDX suite deployment */
    /*------------------------------------------------------------------------*/

    /**
     * @dev Deploys the minimal PYUSDX stack needed for PYUSD→MultiMint migration.
     *      Uses `vm.deployCode` to load pre-compiled 0.8.34 artifacts.
     *      Also deploys a thin SwapAdapter mock that returns the fresh MultiMint
     *      as baseToken, since the on-chain SwapAdapter is wired to the old MultiMint.
     *
     *      Deployment order (resolving SwapFacility↔Factory circular dependency
     *      via nonce-based address prediction):
     *
     *        1. PYUSDX  impl + TUP
     *        2. IssuerGateway  impl + TUP
     *        3. SwapFacility   impl + TUP   (factory address = predicted CREATE2)
     *        4. YieldToOne     impl only
     *        5. MultiMint      impl only
     *        6. ExtensionBeacon impl + TUP
     *        7. ExtensionFactory impl + TUP (at the predicted address)
     *        8. MultiMint      beacon proxy + init
     *        9. Configuration: asset cap, earning, factory registration
     */
    function _deployPyusdxSuite() internal {
        address deployer = address(this);

        /*------------------------------------------------
         * 1. PYUSDX implementation + TransparentUpgradeableProxy
         *------------------------------------------------*/
        bytes memory pyusdxCode = vm.getCode(ART_PYUSDX);
        address pyusdxImpl;

        assembly {
            pyusdxImpl := create(0, add(pyusdxCode, 0x20), mload(pyusdxCode))
        }

        require(pyusdxImpl != address(0), "PYUSDX impl deploy failed");

        bytes memory tupCode = abi.encodePacked(vm.getCode(ART_TUP), abi.encode(pyusdxImpl, deployer, bytes("")));
        address _pyusdxProxy;

        assembly {
            _pyusdxProxy := create(0, add(tupCode, 0x20), mload(tupCode))
        }

        require(_pyusdxProxy != address(0), "PYUSDX proxy deploy failed");
        pyusdxProxy = _pyusdxProxy;

        // Verify proxy is properly wired
        bytes32 implSlot = vm.load(pyusdxProxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        require(address(uint160(uint256(implSlot))) == pyusdxImpl, "Impl slot mismatch");

        // Initialize PYUSDX
        IPYUSDX(pyusdxProxy)
            .initialize(
                IPYUSDX.InitializeParams({
                    name: "PYUSDX",
                    symbol: "PYUSDX",
                    admin: deployer,
                    pauser: deployer,
                    freezeManager: deployer,
                    forcedTransferManager: deployer,
                    earnerManager: deployer,
                    rateLimitManager: deployer,
                    issuer: deployer
                })
            );

        /*------------------------------------------------
        * 2. IssuerGateway implementation + TUP
        *------------------------------------------------*/
        address issuerGwImpl = vm.deployCode(ART_ISSUER_GATEWAY, abi.encode(pyusdxProxy));
        address issuerGwProxy = vm.deployCode(ART_TUP, abi.encode(issuerGwImpl, deployer, bytes("")));

        // Initialize IssuerGateway
        IIssuerGateway(issuerGwProxy)
            .initialize(
                deployer, // admin
                deployer, // operator
                deployer, // executor
                uint32(0), // mintDelay
                uint32(1 hours) // mintTTL
            );

        /*------------------------------------------------
         * 3. Predict future deployment addresses from nonce
         *------------------------------------------------*/
        uint256 n = vm.getNonce(deployer);

        // Upcoming deployments (each vm.deployCode = 1 CREATE):
        //   n+0: SwapFacility impl
        //   n+1: SwapFacility TUP
        //   n+2: YieldToOne impl
        //   n+3: MultiMint impl
        //   n+4: ExtensionBeacon impl
        //   n+5: ExtensionBeacon TUP
        //   n+6: ExtensionFactory impl
        //   n+7: ExtensionFactory TUP
        //   n+8: MultiMint beacon proxy
        address predictedSfProxy = vm.computeCreateAddress(deployer, n + 1);
        address predictedFactoryProxy = vm.computeCreateAddress(deployer, n + 7);

        /*------------------------------------------------
         * 4. SwapFacility implementation + TUP
         *------------------------------------------------*/
        address sfImpl = vm.deployCode(ART_SWAP_FACILITY, abi.encode(pyusdxProxy, predictedFactoryProxy));
        swapFacilityProxy = vm.deployCode(ART_TUP, abi.encode(sfImpl, deployer, bytes("")));

        // Initialize SwapFacility
        ISwapFacilityInit(swapFacilityProxy).initialize(deployer, deployer);

        /*------------------------------------------------
         * 5. Extension implementations (no proxy needed)
         *------------------------------------------------*/
        address ytoImpl = vm.deployCode(ART_YIELD_TO_ONE, abi.encode(pyusdxProxy, swapFacilityProxy));
        address mmImpl = vm.deployCode(ART_MULTI_MINT, abi.encode(pyusdxProxy, swapFacilityProxy));

        /*------------------------------------------------
         * 6. ExtensionBeacon implementation + TUP
         *------------------------------------------------*/
        address beaconImpl = vm.deployCode(ART_BEACON, abi.encode(pyusdxProxy, swapFacilityProxy));
        address beaconProxy = vm.deployCode(ART_TUP, abi.encode(beaconImpl, deployer, bytes("")));

        // Initialize ExtensionBeacon
        IExtensionBeaconInit(beaconProxy).initialize(deployer, deployer, ytoImpl, mmImpl);

        /*------------------------------------------------
         * 7. ExtensionFactory implementation + TUP
         *------------------------------------------------*/
        address factoryImpl = vm.deployCode(ART_FACTORY, abi.encode(pyusdxProxy, swapFacilityProxy, beaconProxy));
        address factoryProxy = vm.deployCode(ART_TUP, abi.encode(factoryImpl, deployer, bytes("")));

        // Initialize ExtensionFactory
        IExtensionFactoryInit(factoryProxy).initialize(deployer, deployer);

        require(factoryProxy == predictedFactoryProxy, "Factory address mismatch");

        /*------------------------------------------------
         * 8. MultiMint beacon proxy
         *------------------------------------------------*/
        // ExtensionType.MULTI_MINT = 2
        bytes memory mmInitData = abi.encodeCall(
            IMultiMintInit.initialize,
            (
                "MultiMint USDai",
                "mmUSDai",
                STAKED_USDAI, // yieldRecipient
                deployer, // admin
                deployer, // assetCapManager
                deployer, // freezeManager
                deployer, // pauser
                deployer, // yieldRecipientManager
                deployer // versionManager
            )
        );

        multiMintProxy = vm.deployCode(ART_BEACON_PROXY, abi.encode(beaconProxy, uint8(2), mmInitData));

        /*------------------------------------------------
         * 9. Configuration
         *------------------------------------------------*/
        // Register MultiMint in factory
        IExtensionFactoryInit(factoryProxy).setExtensionType(multiMintProxy, uint8(2));

        // Set PYUSD asset cap on MultiMint (type(uint256).max)
        IMultiMintInit(multiMintProxy).setAssetCap(PYUSD, type(uint256).max);

        // Start earning on PYUSDX for MultiMint (earnerRate = 5%, feeRate = 0, claimRecipient = self)
        IPYUSDX(pyusdxProxy).setAccountInfo(multiMintProxy, uint32(500), uint16(0), multiMintProxy);

        /*------------------------------------------------
         * 10. Deploy thin SwapAdapter mock pointing to fresh MultiMint
         *------------------------------------------------*/
        swapAdapter = address(new SwapAdapterMock(multiMintProxy));
    }

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function _performUpgrade() internal {
        USDai newImpl = new USDai(swapAdapter, STAKED_USDAI, swapFacilityProxy);

        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(USDAI_PROXY),
            address(newImpl),
            abi.encodeWithSelector(USDai.initializeV1_5.selector)
        );
    }

    /*------------------------------------------------------------------------*/
    /* Tests */
    /*------------------------------------------------------------------------*/

    function test__storagePreservedAfterUpgrade() public {
        IUSDai usdai = IUSDai(USDAI_PROXY);

        uint256 totalSupplyBefore = usdai.totalSupply();
        uint256 bridgedSupplyBefore = usdai.bridgedSupply();
        uint256 supplyCapBefore = usdai.supplyCap();

        assertGt(totalSupplyBefore, 0, "Total supply should be nonzero before upgrade");
        assertGt(supplyCapBefore, 0, "Supply cap should be nonzero before upgrade");

        _performUpgrade();

        assertEq(usdai.totalSupply(), totalSupplyBefore, "totalSupply changed after upgrade");
        assertEq(usdai.bridgedSupply(), bridgedSupplyBefore, "bridgedSupply changed after upgrade");
        assertEq(usdai.supplyCap(), supplyCapBefore, "supplyCap changed after upgrade");
    }

    function test__pyusdMigratedToMultiMint() public {
        uint256 pyusdBefore = IERC20(PYUSD).balanceOf(USDAI_PROXY);
        assertGt(pyusdBefore, 0, "Expected nonzero PYUSD balance before upgrade");

        _performUpgrade();

        assertEq(IERC20(PYUSD).balanceOf(USDAI_PROXY), 0, "USDai proxy should hold no PYUSD after migration");
        assertEq(
            IERC20(multiMintProxy).balanceOf(USDAI_PROXY),
            pyusdBefore,
            "USDai proxy MultiMint balance should equal pre-upgrade PYUSD amount (1:1 wrap)"
        );

        assertEq(
            IERC20(PYUSD).balanceOf(multiMintProxy),
            pyusdBefore,
            "MultiMint should hold the migrated PYUSD as backing"
        );
    }

    function test__rateTierFunctionsRevertAfterUpgrade() public {
        _performUpgrade();

        IUSDai.RateTier[] memory rateTiers = new IUSDai.RateTier[](1);
        rateTiers[0] = IUSDai.RateTier({rate: 1e18, threshold: type(uint256).max});

        vm.expectRevert(IUSDai.InvalidParameters.selector);
        IUSDai(USDAI_PROXY).setRateTiers(rateTiers);
    }

    function test__baseYieldAccruedFromMultiMintAfterUpgrade() public {
        _performUpgrade();

        /* baseYieldAccrued now reads from MultiMint yield — should not revert */
        IUSDai(USDAI_PROXY).baseYieldAccrued();
    }

    function test__versionIs15AfterUpgrade() public {
        _performUpgrade();
        assertEq(USDai(payable(USDAI_PROXY)).IMPLEMENTATION_VERSION(), "1.5");
    }
}
