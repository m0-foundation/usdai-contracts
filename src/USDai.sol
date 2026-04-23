// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";

import "./interfaces/IUSDai.sol";
import "./interfaces/ISwapAdapter.sol";
import "./interfaces/IMintableBurnable.sol";

import "./interfaces/external/IBlacklist.sol";
import "./interfaces/external/IMultiMint.sol";
import "./interfaces/external/ISwapFacility.sol";

/**
 * @title USDai ERC20
 * @author MetaStreet Foundation
 */
contract USDai is
    IUSDai,
    IMintableBurnable,
    ERC165Upgradeable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    MulticallUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;

    /*------------------------------------------------------------------------*/
    /* Constant */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Implementation version
     */
    string public constant IMPLEMENTATION_VERSION = "1.5";

    /**
     * @notice Bridge admin role
     */
    bytes32 internal constant BRIDGE_ADMIN_ROLE = keccak256("BRIDGE_ADMIN_ROLE");

    /**
     * @notice Deposit admin role
     */
    bytes32 internal constant DEPOSIT_ADMIN_ROLE = keccak256("DEPOSIT_ADMIN_ROLE");

    /**
     * @notice Blacklist admin role
     */
    bytes32 internal constant BLACKLIST_ADMIN_ROLE = keccak256("BLACKLIST_ADMIN_ROLE");

    /**
     * @notice Supply storage location
     * @dev keccak256(abi.encode(uint256(keccak256("USDai.supply")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant SUPPLY_STORAGE_LOCATION =
        0x5fc387bd350b82c09f22bee4c04d61669980ce519c352560e36bc6144f9cf800;

    /**
     * @notice Base yield accrual storage location (DEAD — kept for storage layout compatibility)
     * @dev keccak256(abi.encode(uint256(keccak256("USDai.baseYieldAccrual")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant BASE_YIELD_ACCRUAL_STORAGE_LOCATION =
        0xad76c5b481cb106971e0ae4c23a09cb5b1dc9dba5fad96d9694630df5e853900;

    /**
     * @notice Blacklist storage location
     * @dev keccak256(abi.encode(uint256(keccak256("USDai.blacklist")) - 1)) & ~bytes32(uint256(0xff));
     */
    bytes32 private constant BLACKLIST_STORAGE_LOCATION =
        0xd21f45001ca28b8905ef527bd860800b2646ce7faf578b00aa2e89af23551500;

    /**
     * @notice PYUSD on Arbitrum
     */
    address private constant PYUSD = 0x46850aD61C2B7d64d08c9C754F45254596696984;

    /*------------------------------------------------------------------------*/
    /* Immutable state */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Swap adapter
     */
    ISwapAdapter internal immutable _swapAdapter;

    /**
     * @notice Base token (MultiMint)
     */
    IERC20 internal immutable _baseToken;

    /**
     * @notice Scale factor
     */
    uint256 internal immutable _scaleFactor;

    /**
     * @notice Base yield recipient (sUSDai)
     */
    address internal immutable _baseYieldRecipient;

    /**
     * @notice Swap facility (for PYUSD → MultiMint migration)
     */
    address internal immutable _swapFacility;

    /*------------------------------------------------------------------------*/
    /* Constructor */
    /*------------------------------------------------------------------------*/

    /**
     * @notice USDai Constructor
     * @param swapAdapter_ Swap Adapter
     * @param baseYieldRecipient_ Base yield recipient
     * @param swapFacility_ PYUSDX SwapFacility address
     */
    constructor(
        address swapAdapter_,
        address baseYieldRecipient_,
        address swapFacility_
    ) {
        _disableInitializers();

        _swapAdapter = ISwapAdapter(swapAdapter_);
        _baseToken = IERC20(_swapAdapter.baseToken());
        _scaleFactor = 10 ** (18 - IERC20Metadata(_swapAdapter.baseToken()).decimals());
        _baseYieldRecipient = baseYieldRecipient_;
        _swapFacility = swapFacility_;
    }

    /*------------------------------------------------------------------------*/
    /* Initialization  */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Initialize the contract
     * @param admin Default admin address
     */
    function initialize(
        address admin
    ) public initializer {
        __ERC20_init("USDai", "USDai");
        __ERC20Permit_init("USDai");
        __Multicall_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        /* Grant roles */
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /**
     * @notice V1.5 migration: atomically wraps PYUSD → MultiMint
     * @dev    Called via upgradeAndCall during the v1.5 upgrade.
     */
    function initializeV1_5() public reinitializer(3) {
        IERC20 pyusd = IERC20(PYUSD);

        uint256 pyusdBalance = pyusd.balanceOf(address(this));
        if (pyusdBalance == 0) revert InvalidAmount();

        /* Approve SwapFacility to pull PYUSD */
        pyusd.forceApprove(_swapFacility, pyusdBalance);

        /* Wrap PYUSD → MultiMint, delivered to this contract 1:1 */
        uint256 mintedBefore = _baseToken.balanceOf(address(this));

        ISwapFacility(_swapFacility).swap(PYUSD, address(_baseToken), pyusdBalance, address(this));

        uint256 minted = _baseToken.balanceOf(address(this)) - mintedBefore;

        /* Solvency assertion: USDai (18d) totalSupply ≤ MultiMint balance × 10^12 */
        if (_scale(minted) < totalSupply() + bridgedSupply()) revert InsufficientBacking();

        emit Migrated("PYUSD -> MultiMint", abi.encode(pyusdBalance, minted));
    }

    /*------------------------------------------------------------------------*/
    /* Modifiers  */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Non-zero value modifier
     * @param value Value to check
     */
    modifier nonZeroUint(
        uint256 value
    ) {
        if (value == 0) revert InvalidAmount();
        _;
    }

    /**
     * @notice Non-zero address modifier
     * @param value Value to check
     */
    modifier nonZeroAddress(
        address value
    ) {
        if (value == address(0)) revert InvalidAddress();
        _;
    }

    /**
     * @notice Not blacklisted modifier
     * @param value Value to check
     */
    modifier notBlacklisted(
        address value
    ) {
        if (isBlacklisted(value)) {
            revert BlacklistedAddress(value);
        }
        _;
    }

    /*------------------------------------------------------------------------*/
    /* Getters  */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IUSDai
     */
    function swapAdapter() external view returns (address) {
        return address(_swapAdapter);
    }

    /**
     * @inheritdoc IUSDai
     */
    function baseToken() external view returns (address) {
        return address(_baseToken);
    }

    /**
     * @inheritdoc IUSDai
     */
    function bridgedSupply() public view returns (uint256) {
        return _getSupplyStorage().bridged;
    }

    /**
     * @inheritdoc IUSDai
     */
    function supplyCap() public view returns (uint256) {
        return _getSupplyStorage().cap;
    }

    /**
     * @inheritdoc IUSDai
     * @dev Returns the pending yield from MultiMint, scaled to 18 decimals.
     */
    function baseYieldAccrued() external view returns (uint256) {
        return _scale(IMultiMint(address(_baseToken)).yield());
    }

    /**
     * @inheritdoc IUSDai
     */
    function isBlacklisted(
        address account
    ) public view returns (bool) {
        /* Check local blacklist */
        if (_getBlacklistStorage().blacklist[account]) return true;

        /* If not on Arbitrum, skip remaining checks */
        if (block.chainid != 42161) return false;

        /* Exclude Staked USDai and OUSDaiUtility */
        if (
            account == 0x0B2b2B2076d95dda7817e785989fE353fe955ef9
                || account == 0x24a92E28a8C5D8812DcfAf44bCb20CC0BaBd1392
        ) return false;

        /* Check USDC and USDT blacklists */
        return IBlacklist(0xaf88d065e77c8cC2239327C5EDb3A432268e5831).isBlacklisted(account)
            || IBlacklist(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9).isBlocked(account);
    }

    /*------------------------------------------------------------------------*/
    /* Internal helpers */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get reference to USDai supply storage
     * @return $ Reference to supply storage
     */
    function _getSupplyStorage() internal pure returns (Supply storage $) {
        assembly {
            $.slot := SUPPLY_STORAGE_LOCATION
        }
    }

    /**
     * @notice Get reference to USDai base yield accrual storage
     *
     * @return $ Reference to base yield accrual storage
     */
    function _getBaseYieldAccrualStorage() internal pure returns (BaseYieldAccrual storage $) {
        assembly {
            $.slot := BASE_YIELD_ACCRUAL_STORAGE_LOCATION
        }
    }

    /**
     * @notice Get reference to USDai blacklist storage
     *
     * @return $ Reference to blacklist storage
     */
    function _getBlacklistStorage() internal pure returns (Blacklist storage $) {
        assembly {
            $.slot := BLACKLIST_STORAGE_LOCATION
        }
    }

    /**
     * @notice Helper function to scale up a value
     * @param value Value
     * @return Scaled value
     */
    function _scale(
        uint256 value
    ) public view returns (uint256) {
        return value * _scaleFactor;
    }

    /**
     * @notice Helper function to scale down a value
     * @param value Value
     * @return Unscaled value
     */
    function _unscale(
        uint256 value
    ) public view returns (uint256) {
        return value / _scaleFactor;
    }

    /**
     * @notice Helper function to scale down a value, rounding up
     * @param value Value
     * @return Unscaled value rounded up
     */
    function _unscaleUp(
        uint256 value
    ) public view returns (uint256) {
        return (value + _scaleFactor - 1) / _scaleFactor;
    }

    /**
     * @notice Deposit
     * @param depositToken Deposit token
     * @param depositAmount Deposit amount
     * @param usdaiAmountMinimum USDai amount minimum
     * @param recipient Recipient address
     * @param data Data
     * @return USDai amount
     */
    function _deposit(
        address depositToken,
        uint256 depositAmount,
        uint256 usdaiAmountMinimum,
        address recipient,
        bytes calldata data
    ) internal nonZeroUint(depositAmount) nonZeroAddress(recipient) returns (uint256) {
        /* Transfer token in from sender to this contract */
        IERC20(depositToken).safeTransferFrom(msg.sender, address(this), depositAmount);

        /* If the deposit token isn't base token, swap in */
        uint256 usdaiAmount;
        if (depositToken != address(_baseToken)) {
            /* Approve the adapter to spend the token in */
            IERC20(depositToken).forceApprove(address(_swapAdapter), depositAmount);

            /* Swap in deposit token for base token */
            usdaiAmount = _scale(_swapAdapter.swapIn(depositToken, depositAmount, _unscaleUp(usdaiAmountMinimum), data));
        } else {
            usdaiAmount = _scale(depositAmount);
        }

        /* Check if the supply cap is exceeded */
        if (!hasRole(DEPOSIT_ADMIN_ROLE, msg.sender) && usdaiAmount + totalSupply() + bridgedSupply() > supplyCap()) {
            revert SupplyCapExceeded();
        }

        /* Mint to the recipient */
        _mint(recipient, usdaiAmount);

        /* Emit deposited event */
        emit Deposited(msg.sender, recipient, depositToken, depositAmount, usdaiAmount);

        return usdaiAmount;
    }

    /**
     * @notice Withdraw
     * @param withdrawToken Withdraw token
     * @param usdaiAmount USD.ai amount
     * @param withdrawAmountMinimum Minimum withdraw amount (only checked for non-base token withdrawals)
     * @param recipient Recipient address
     * @param data Data
     * @return Withdraw amount
     */
    function _withdraw(
        address withdrawToken,
        uint256 usdaiAmount,
        uint256 withdrawAmountMinimum,
        address recipient,
        bytes calldata data
    ) internal nonZeroUint(usdaiAmount) nonZeroAddress(recipient) returns (uint256) {
        /* Burn USD.ai tokens */
        _burn(msg.sender, usdaiAmount);

        /* If the withdraw token isn't base token, swap out */
        uint256 withdrawAmount;
        if (withdrawToken != address(_baseToken)) {
            uint256 baseTokenAmount = _unscale(usdaiAmount);

            /* Approve the adapter to spend the token in */
            _baseToken.forceApprove(address(_swapAdapter), baseTokenAmount);

            /* Swap base token input for withdraw token */
            withdrawAmount = _swapAdapter.swapOut(withdrawToken, baseTokenAmount, withdrawAmountMinimum, data);
        } else {
            withdrawAmount = _unscale(usdaiAmount);
        }

        /* Transfer token output from this contract to the recipient address */
        IERC20(withdrawToken).safeTransfer(recipient, withdrawAmount);

        /* Emit withdrawn event */
        emit Withdrawn(msg.sender, recipient, withdrawToken, usdaiAmount, withdrawAmount);

        return withdrawAmount;
    }

    /*------------------------------------------------------------------------*/
    /* ERC20Upgradeable overrides */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc ERC20Upgradeable
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override notBlacklisted(msg.sender) notBlacklisted(from) notBlacklisted(to) {
        super._update(from, to, value);
    }

    /*------------------------------------------------------------------------*/
    /* Public API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IUSDai
     */
    function deposit(
        address depositToken,
        uint256 depositAmount,
        uint256 usdaiAmountMinimum,
        address recipient
    ) external nonReentrant returns (uint256) {
        return _deposit(depositToken, depositAmount, usdaiAmountMinimum, recipient, msg.data[0:0]);
    }

    /**
     * @inheritdoc IUSDai
     */
    function deposit(
        address depositToken,
        uint256 depositAmount,
        uint256 usdaiAmountMinimum,
        address recipient,
        bytes calldata data
    ) external nonReentrant returns (uint256) {
        return _deposit(depositToken, depositAmount, usdaiAmountMinimum, recipient, data);
    }

    /**
     * @inheritdoc IUSDai
     */
    function withdraw(
        address withdrawToken,
        uint256 usdaiAmount,
        uint256 withdrawAmountMinimum,
        address recipient
    ) external nonReentrant returns (uint256) {
        return _withdraw(withdrawToken, usdaiAmount, withdrawAmountMinimum, recipient, msg.data[0:0]);
    }

    /**
     * @inheritdoc IUSDai
     */
    function withdraw(
        address withdrawToken,
        uint256 usdaiAmount,
        uint256 withdrawAmountMinimum,
        address recipient,
        bytes calldata data
    ) external nonReentrant returns (uint256) {
        return _withdraw(withdrawToken, usdaiAmount, withdrawAmountMinimum, recipient, data);
    }

    /*------------------------------------------------------------------------*/
    /* Minter API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IMintableBurnable
     */
    function mint(
        address to,
        uint256 amount
    ) external onlyRole(BRIDGE_ADMIN_ROLE) {
        _mint(to, amount);

        /* Update bridged supply */
        _getSupplyStorage().bridged -= amount;
    }

    /**
     * @inheritdoc IMintableBurnable
     */
    function burn(
        address from,
        uint256 amount
    ) external onlyRole(BRIDGE_ADMIN_ROLE) {
        _burn(from, amount);

        /* Update bridged supply */
        _getSupplyStorage().bridged += amount;
    }

    /*------------------------------------------------------------------------*/
    /* Base Yield Recipient API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IUSDai
     */
    function harvest() external returns (uint256) {
        /* Validate caller is the base yield recipient */
        if (msg.sender != _baseYieldRecipient) revert InvalidAddress();

        /* Claim yield from MultiMint — mints MultiMint to this contract */
        uint256 claimed = IMultiMint(address(_baseToken)).claimYield();
        if (claimed == 0) return 0;

        /* Scale to USDai (18d) */
        uint256 usdaiAmount = _scale(claimed);

        /* Mint USDai to base yield recipient */
        _mint(_baseYieldRecipient, usdaiAmount);

        /* Emit harvested event */
        emit Harvested(usdaiAmount);

        return usdaiAmount;
    }

    /*------------------------------------------------------------------------*/
    /* Permissioned API */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IUSDai
     */
    function setSupplyCap(
        uint256 cap
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getSupplyStorage().cap = cap;

        /* Emit supply cap set event */
        emit SupplyCapSet(cap);
    }

    /**
     * @inheritdoc IUSDai
     */
    function setBlacklist(
        address account,
        bool blacklisted
    ) external onlyRole(BLACKLIST_ADMIN_ROLE) {
        _getBlacklistStorage().blacklist[account] = blacklisted;

        /* Emit blacklist updated event */
        emit BlacklistUpdated(account, blacklisted);
    }

    /**
     * @inheritdoc IUSDai
     * @dev DEAD in v1.5 — always reverts. Kept for interface compatibility.
     */
    function setRateTiers(
        RateTier[] memory
    ) external pure {
        revert InvalidParameters();
    }

    /*------------------------------------------------------------------------*/
    /* ERC165 */
    /*------------------------------------------------------------------------*/

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControlUpgradeable, ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IUSDai).interfaceId
            || interfaceId == type(IMintableBurnable).interfaceId || super.supportsInterface(interfaceId);
    }
}
