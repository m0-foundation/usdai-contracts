// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title MultiMint Interface (thin wrapper for PYUSDX MultiMint)
 * @dev Hand-authored to compile under 0.8.29 without coupling to PYUSDX's 0.8.34 imports.
 *      Only exposes the functions USDai v1.5 needs.
 */
interface IMultiMint {
    /**
     * @notice Claims accrued yield to the yield recipient.
     * @return The amount of yield claimed (in MultiMint decimals = 6).
     */
    function claimYield() external returns (uint256);

    /**
     * @notice Returns the amount of pending accrued yield.
     */
    function yield() external view returns (uint256);

    /**
     * @notice Returns the yield recipient address.
     */
    function yieldRecipient() external view returns (address);

    /**
     * @notice Gets the cached balance of a given asset held by the extension.
     */
    function assetBalanceOf(address asset) external view returns (uint256);

    /**
     * @notice Gets the asset cap for a given asset.
     */
    function assetCap(address asset) external view returns (uint256);

    /**
     * @notice Gets the total non-PYUSDX assets held by the extension (in extension decimals).
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Checks if an asset is allowed as backing.
     */
    function isAllowedAsset(address asset) external view returns (bool);

    /**
     * @notice Checks if unwrapping `amount` of extension tokens is allowed.
     */
    function isAllowedToUnwrap(uint256 amount) external view returns (bool);

    /**
     * @notice Checks if replacing `asset` with the backing asset is allowed.
     */
    function isAllowedToReplaceAsset(address asset, uint256 amount) external view returns (bool);

    /**
     * @notice Gets total supply of the extension token.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Gets the balance of an account.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice The role that can set asset caps.
     */
    function ASSET_CAP_MANAGER_ROLE() external view returns (bytes32);
}
