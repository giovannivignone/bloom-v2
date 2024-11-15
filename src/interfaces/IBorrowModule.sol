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
     * @param rwaAmount The amount of rwa asset collateral at the current time.
     */
    struct TbyCollateral {
        uint128 assetAmount;
        uint128 rwaAmount;
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

    /**
     * @notice Struct representing the maturity range of a TBY.
     * @param start The start timestamp in seconds of the maturity range.
     * @param end The end timestamp in seconds of the maturity range.
     */
    struct TbyMaturity {
        uint128 start;
        uint128 end;
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

    /**
     * @notice Emitted when the maturity time for the next TBY is set.
     * @param maturityLength The length of time in seconds that future TBY Ids will mature for.
     */
    event TbyMaturitySet(uint256 maturityLength);

    /*///////////////////////////////////////////////////////////////
                            Write Functions    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Borrow lenders funds to purchase an RWA asset.
     * @dev This function will be called by the BloomPool.
     * @dev Module Developers need to implement the _purchaseRwa function in order to allow this function to execute successfully.
     * @param borrower The address of the borrower.
     * @param amount The amount of underlying assets that the borrower is borrowering.
     * @return bCollateral Total amount of borrower collateral posted to execute the transaction.
     */
    function borrow(address borrower, uint256 amount) external payable returns (uint256 bCollateral);

    /**
     * @notice Repays ALL borrowers borrowed funds + collateral.
     * @dev This function will be called by the BloomPool.
     * @dev Module Developers need to implement the _getRwaSwapAmount and _repayRwa functions in order to allow this function to execute successfully.
     * @param tbyId The id of the TBY to repay the borrowed assets for.
     * @return lenderReturn The amount of underlying assets that the lender is receiving.
     * @return borrowerReturn The amount of underlying assets that the borrower is receiving.
     */
    function repay(uint256 tbyId) external returns (uint256 lenderReturn, uint256 borrowerReturn);

    /**
     * @notice Transfers the underlying asset collateral back to the recipient.
     * @dev This function will be called by the BloomPool.
     * @param tbyId The id of the TBY to transfer the collateral for.
     * @param amount The amount of collateral to transfer.
     * @param recipient The address of the recipient to transfer the collateral to.
     */
    function transferCollateral(uint256 tbyId, uint256 amount, address recipient) external;

    /**
     * @notice Calculates the TBY id to mint based on the last minted TBY id (in this module), the swap buffer, and the last minted TBY id from the Bloom Pool.
     * @dev This function is called by the Bloom Pool.
     * @dev If the last minted TBY id (from this module) was created 48 hours ago or more, a new TBY id is minted.
     * @return id The id of the TBY to mint.
     */
    function calculateTbyId(uint256 bloomsLastMintedId) external returns (uint256 id);

    /*///////////////////////////////////////////////////////////////
                            View Functions    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current rate of the TBY in terms of USD.
     * @dev The rate is returned as a fixed point number with 18 decimals.
     * @param id The id of the TBY.
     */
    function getRate(uint256 id) external view returns (uint256);

    /// @notice Returns the address of the Bloom Pool.
    function bloomPool() external view returns (address);

    /// @notice Returns the address of the tby token.
    function tby() external view returns (address);

    /// @notice Returns the address of the underlying asset of the pool.
    function asset() external view returns (address);

    /// @notice Returns the address of the RWA token of the pool.
    function rwa() external view returns (address);

    /// @notice Returns the address of the Bloom Oracle.
    function bloomOracle() external view returns (address);

    /// @notice Returns the leverage of the borrow module.
    function leverage() external view returns (uint256);

    /// @notice Returns the spread between the TBY rate and the RWA rate.
    function spread() external view returns (uint256);

    /// @notice Returns the swap buffer for the borrow module.
    function swapBuffer() external view returns (uint256);

    /// @notice Returns the loan duration for the borrow module.
    function loanDuration() external view returns (uint256);

    /// @notice Returns the last TBY id that was minted associated with the borrow module.
    function lastMintedId() external view returns (uint256);

    /**
     * @notice Returns if the user is a valid borrower.
     * @param account The address of the user to check.
     * @return bool True if the user is a valid borrower.
     */
    function isKYCedBorrower(address account) external view returns (bool);

    /**
     * @notice Returns the RWA price ranges for a given TBY id.
     * @param tbyId The id of the TBY to get the RWA price for.
     * @return RwaPrice The RWA price struct for the TBY.
     */
    function rwaPrice(uint256 tbyId) external view returns (RwaPrice memory);

    /**
     * @notice Returns the collateral for a given TBY id.
     * @param tbyId The id of the TBY to get the collateral for.
     * @return TbyCollateral The collateral for the TBY.
     */
    function tbyCollateral(uint256 tbyId) external view returns (TbyCollateral memory);

    /// @notice Returns the TbyMaturity struct containing the start and end timestamps of a given Tby ID.
    function tbyMaturity(uint256 id) external view returns (TbyMaturity memory);
}
