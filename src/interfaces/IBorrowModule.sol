// SPDX-License-Identifier: MIT
/*
██████╗░██╗░░░░░░█████╗░░█████╗░███╗░░░███╗
██╔══██╗██║░░░░░██╔══██╗██╔══██╗████╗░████║
██████╦╝██║░░░░░██║░░██║██║░░██║██╔████╔██║
██╔══██╗██║░░░░░██║░░██║██║░░██║██║╚██╔╝██║
██████╦╝███████╗╚█████╔╝╚█████╔╝██║░╚═╝░██║
╚═════╝░╚══════╝░╚════╝░░╚════╝░╚═╝░░░░░╚═╝
*/
pragma solidity 0.8.27;

interface IBorrowModule {
    /*///////////////////////////////////////////////////////////////
                                Structs
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Struct representing the collateral backed by a TBY.
     * @param assetAmount The amount of underlying asset collateral.
     * @param currentRwaAmount The amount of rwa asset collateral at the current time.
     * @param originalRwaAmount The amount of rwa asset collateral at the start of the TBY (will only be set at the end of the TBYs maturity for accounting purposes)
     */
    struct TbyCollateral {
        uint128 assetAmount;
        uint128 currentRwaAmount;
        uint128 originalRwaAmount;
    }

    /**
     * @notice Struct to store the price range for RWA assets at the time of TBY start and end times.
     * @param startPrice The starting price of the RWA at the time of the borrower swap.
     * @param endPrice  The ending price of the RWA at the time of the borrower swap.
     * @param spread The spread for the TBY.
     */
    struct RwaPrice {
        uint128 startPrice;
        uint128 endPrice;
        uint128 spread;
    }

    /*///////////////////////////////////////////////////////////////
                              Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a borrower is KYCed.
    event BorrowerKyced(address indexed account, bool isKyced);

    /// @notice Emitted when the spread is updated.
    event SpreadSet(uint256 spread);

    /**
     * @notice Emitted when the borrowers leverage amount is updated
     * @param leverage The updated leverage amount for the borrower.
     */
    event LeverageSet(uint256 leverage);

    /*///////////////////////////////////////////////////////////////
                            Functions    
    //////////////////////////////////////////////////////////////*/

    function borrow(address borrower, uint256 amount) external returns (uint256 bCollateral);

    function repay(uint256 tbyId, address borrower) external returns (uint256 lenderReturn, uint256 borrowerReturn, bool isRedeemable);

    function transferCollateral(uint256 tbyId, uint256 amount, address recipient) external;

    /// @notice Returns the address of the underlying asset of the pool.
    function asset() external view returns (address);

    /// @notice Returns the address of the RWA token of the pool.
    function rwa() external view returns (address);

    /// @notice Returns the address of the Bloom Oracle.
    function bloomOracle() external view returns (address);

    /// @notice Returns the address of the Bloom Pool.
    function bloomPool() external view returns (address);

    /**
     * @notice Returns if the user is a valid borrower.
     * @param account The address of the user to check.
     * @return bool True if the user is a valid borrower.
     */
    function isKYCedBorrower(address account) external view returns (bool);

    /// @notice Returns the spread between the TBY rate and the RWA rate.
    function spread() external view returns (uint256);

    /// @notice Returns the leverage of the borrow module.
    function leverage() external view returns (uint256);

    /// @notice Returns the last TBY id that was minted associated with the borrow module.
    function lastMintedId() external view returns (uint256);

    /// @notice Sets the last minted TBY id associated with the borrow module.
    function setLastMintedId(uint256 id) external;

    /// @notice Returns the swap buffer for the borrow module.
    function swapBuffer() external view returns (uint256);

    /// @notice Returns the loan duration for the borrow module.
    function loanDuration() external view returns (uint256);
}
