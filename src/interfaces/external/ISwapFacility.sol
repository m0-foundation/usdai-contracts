// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title SwapFacility Interface (thin wrapper for PYUSDX SwapFacility)
 * @dev Hand-authored to compile under 0.8.29 without coupling to PYUSDX's 0.8.34 imports.
 *      Only exposes the functions USDai v1.5 and the swap adapter need.
 */
interface ISwapFacility {
    /**
     * @notice Swaps between two tokens, which can be PYUSDX, PYUSDX Extensions, or an external asset.
     * @param tokenIn   The address of the token to swap from.
     * @param tokenOut  The address of the token to swap to.
     * @param amount    The amount to swap.
     * @param recipient The address to receive the swapped tokens.
     */
    function swap(address tokenIn, address tokenOut, uint256 amount, address recipient) external;

    /**
     * @notice Swaps PYUSDX token to PYUSDX Extension.
     * @param extensionOut The address of the PYUSDX Extension to swap to.
     * @param amount       The amount of PYUSDX token to swap.
     * @param recipient    The address to receive the swapped PYUSDX Extension tokens.
     */
    function swapIn(address extensionOut, uint256 amount, address recipient) external;

    /**
     * @notice Swaps PYUSDX Extension to PYUSDX token.
     * @param extensionIn The address of the PYUSDX Extension to swap from.
     * @param amount      The amount of PYUSDX Extension tokens to swap.
     * @param recipient   The address to receive PYUSDX tokens.
     */
    function swapOut(address extensionIn, uint256 amount, address recipient) external;

    /**
     * @notice Returns the address that called swap.
     */
    function msgSender() external view returns (address);

    /**
     * @notice Checks if the extension is approved.
     */
    function isApprovedExtension(address extension) external view returns (bool);

    /**
     * @notice The address of the PYUSDX Token contract.
     */
    function pyusdx() external view returns (address);
}
