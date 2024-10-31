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

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib as FpMath} from "@solady/utils/FixedPointMathLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

import {BloomErrors as Errors} from "@bloom-v2/helpers/BloomErrors.sol";
import {IBloomPool} from "@bloom-v2/interfaces/IBloomPool.sol";
import {IBorrowModule} from "@bloom-v2/interfaces/IBorrowModule.sol";
import {IBloomOracle} from "@bloom-v2/interfaces/IBloomOracle.sol";
import {ITby} from "@bloom-v2/interfaces/ITby.sol";
/**
 * @title BorrowModule
 * @notice Reusable logic for building borrow modules on the Bloom Protocol.
 */
abstract contract BorrowModule is IBorrowModule, Ownable {
    using FpMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice Leverage value for the borrower. scaled by 1e18 (20x leverage == 20e18)
    uint256 internal _leverage;

    /// @notice The spread between the rate of the TBY and the rate of the RWA token.
    uint256 internal _spread;

    /// @notice The buffer to account for the swap slippage.
    uint256 internal _swapBuffer;

    /// @notice The duration of the loan in seconds.
    uint256 internal _loanDuration;

    /// @notice Mapping of borrower addresses to their KYC status.
    mapping(address => bool) internal _borrowers;

    /// @notice The last TBY id that was minted associated with the borrow module.
    uint256 internal _lastMintedId;

    /// @notice Mapping of TBY ids to the RWA pricing ranges.
    mapping(uint256 => RwaPrice) internal _tbyIdToRwaPrice;

    /// @notice A mapping of the TBY id to the collateral that is backed by the tokens.
    mapping(uint256 => TbyCollateral) internal _idToCollateral;

    /*///////////////////////////////////////////////////////////////
                        Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice The Bloom Pool contract.
    IBloomPool internal immutable _bloomPool;

    /// @notice The TBY contract.
    ITby internal immutable _tby;

    /// @notice The underlying asset of the pool.
    IERC20 internal immutable _asset;

    /// @notice The RWA token of the pool.
    IERC20 internal immutable _rwa;

    /// @notice The Bloom Oracle contract.
    IBloomOracle internal immutable _bloomOracle;

    /// @notice The scaling factor for the asset.
    uint256 internal immutable _assetScalingFactor;

    /// @notice The upper bound leverage allowed for pool (Cant be set to 100x but just under).
    uint256 constant MAX_LEVERAGE = 100e18;

    /// @notice Minimum spread between the TBY rate and the rate of the RWA's price appreciation.
    uint256 constant MIN_SPREAD = 0.85e18;

    /*///////////////////////////////////////////////////////////////
                            Modifiers    
    //////////////////////////////////////////////////////////////*/

    modifier KycBorrower(address borrower) {
        require(isKYCedBorrower(borrower), Errors.KYCFailed());
        _;
    }

    modifier onlyBloomPool() {
        require(msg.sender == address(_bloomPool), Errors.NotBloom());
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            Constructor    
    //////////////////////////////////////////////////////////////*/

    constructor(
        address bloomPool_,
        address bloomOracle_,
        address rwa_,
        uint256 initLeverage,
        uint256 initSpread,
        address owner_
    ) Ownable(owner_) {
        require(bloomPool_ != address(0) && rwa_ != address(0) && bloomOracle_ != address(0), Errors.ZeroAddress());

        address asset_ = IBloomPool(bloomPool_).asset();
        _asset = IERC20(asset_);
        _bloomPool = IBloomPool(bloomPool_);
        _tby = ITby(IBloomPool(bloomPool_).tby());
        _rwa = IERC20(rwa_);
        _bloomOracle = IBloomOracle(bloomOracle_);

        _assetScalingFactor = 10 ** IERC20Metadata(asset_).decimals();

        _setLeverage(initLeverage);
        _setSpread(initSpread);
    }

    /*///////////////////////////////////////////////////////////////
                            External Functions    
    //////////////////////////////////////////////////////////////*/

    function borrow(address borrower, uint256 amount)
        external
        override
        onlyBloomPool
        KycBorrower(borrower)
        returns (uint256 bCollateral)
    {
        bCollateral = amount.divWadUp(_leverage);
        require(bCollateral > 0, Errors.ZeroAmount());

        uint256 totalCollateral = amount + bCollateral;
        uint256 rwaPriceUsd = _bloomOracle.getPriceUsd(address(_rwa));

        uint256 rwaBalanceBefore = _rwa.balanceOf(address(this));
        uint256 rwaAmount = _purchaseRwa(borrower, totalCollateral, rwaPriceUsd);
        // validate that we have received enough RWA tokens
        uint256 rwaBalanceAfter = _rwa.balanceOf(address(this));
        require(rwaBalanceAfter - rwaBalanceBefore == rwaAmount, Errors.ExceedsSlippage());

        TbyCollateral storage collateral = _idToCollateral[_lastMintedId];
        collateral.currentRwaAmount += uint128(rwaAmount);
        _setStartPrice(_lastMintedId, rwaPriceUsd, rwaAmount, collateral.currentRwaAmount);
    }

    function repay(uint256 tbyId, address borrower) external onlyBloomPool KycBorrower(borrower) returns (uint256 lenderReturn, uint256 borrowerReturn, bool isRedeemable) {
        uint256 rwaAmount = _getRwaSwapAmount(tbyId);
        require(rwaAmount > 0, Errors.ZeroAmount());

        TbyCollateral storage collateral = _idToCollateral[tbyId];        
        if (collateral.originalRwaAmount == 0) {
            collateral.originalRwaAmount = uint128(rwaAmount);
        }
        
        // Cannot swap out more RWA tokens than is allocated for the TBY.
        rwaAmount = FpMath.min(rwaAmount, collateral.currentRwaAmount);

        uint256 percentSwapped = rwaAmount.divWad(collateral.originalRwaAmount);
        uint256 tbyTotalSupply = _tby.totalSupply(tbyId);
        uint256 tbyAmount = percentSwapped != FpMath.WAD ? tbyTotalSupply.mulWad(percentSwapped) : tbyTotalSupply;
        lenderReturn = getRate(tbyId).mulWad(tbyAmount);

        uint256 assetBalanceBefore = _asset.balanceOf(address(this));
        uint256 assetAmount = _repayRwa(rwaAmount);
        uint256 assetBalanceAfter = _asset.balanceOf(address(this));
        require(assetBalanceAfter - assetBalanceBefore == assetAmount, Errors.ExceedsSlippage());

        uint256 rwaPriceUsd = _bloomOracle.getPriceUsd(address(_rwa));
        RwaPrice storage rwaPrice = _tbyIdToRwaPrice[tbyId];

        // If the price has dropped between the end of the TBY's maturity date and when the market maker swap finishes,
        //     only the borrower's returns will be negatively impacted, unless the rate of the drop in price is so large,
        //     that the lender's returns are less than their implied rate. In this case, the rate will be adjusted to
        //     reflect the price of the new assets entering the pool. This adjustment is to ensure that lender returns always
        //     match up with the implied rate of the TBY.
        if (rwaPriceUsd < rwaPrice.endPrice) {
            if (lenderReturn > assetAmount) {
                lenderReturn = assetAmount;
                uint256 accumulatedCollateral = _bloomPool.lenderReturns(tbyId) + lenderReturn;
                uint256 remainingAmount =
                    (collateral.currentRwaAmount - rwaAmount).mulWad(rwaPriceUsd) / _assetScalingFactor;
                uint256 totalCollateral = accumulatedCollateral + remainingAmount;
                uint256 newRate = totalCollateral.divWad(_tby.totalSupply(tbyId));
                uint256 adjustedRate = _takeSpread(newRate, rwaPrice.spread);
                rwaPrice.endPrice = uint128(adjustedRate.mulWad(rwaPrice.startPrice));
            }
        }
        borrowerReturn = assetAmount - lenderReturn;

        collateral.currentRwaAmount -= uint128(rwaAmount);
        collateral.assetAmount += uint128(assetAmount);

        if (collateral.currentRwaAmount == 0) {
            isRedeemable = true;
        }
    }

    function transferCollateral(uint256 tbyId, uint256 amount, address recipient) external onlyBloomPool {
        _idToCollateral[tbyId].assetAmount -= uint128(amount);
        IERC20(_asset).safeTransfer(recipient, amount);
    }

    function setLastMintedId(uint256 id) external onlyBloomPool {
        _lastMintedId = id;
    }

    function setSwapBuffer(uint256 buffer) external onlyOwner {
        _swapBuffer = buffer;
    }

    function setLoanDuration(uint256 duration) external onlyOwner {
        _loanDuration = duration;
    }

    /**
     * @notice Whitelists an address to be a KYCed borrower.
     * @dev Only the owner can call this function.
     * @param account The address of the borrower to whitelist.
     * @param isKyced True to whitelist, false to remove from whitelist.
     */
    function whitelistBorrower(address account, bool isKyced) external onlyOwner {
        _borrowers[account] = isKyced;
        emit BorrowerKyced(account, isKyced);
    }

    /*///////////////////////////////////////////////////////////////
                            View Functions    
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBorrowModule
    function asset() external view returns (address) {
        return address(_asset);
    }

    /// @inheritdoc IBorrowModule
    function rwa() external view returns (address) {
        return address(_rwa);
    }

    /// @inheritdoc IBorrowModule
    function bloomOracle() external view returns (address) {
        return address(_bloomOracle);
    }

    /// @inheritdoc IBorrowModule
    function isKYCedBorrower(address account) public view returns (bool) {
        return _borrowers[account];
    }

    /**
     * @notice Updates the leverage for future borrower fills
     * @dev Leverage is scaled to 1e18. (20x leverage = 20e18)
     * @param leverage Updated leverage
     */
    function setLeverage(uint256 leverage) external onlyOwner {
        _setLeverage(leverage);
    }

    /**
     * @notice Updates the spread between the TBY rate and the RWA rate.
     * @param spread_ The new spread value.
     */
    function setSpread(uint256 spread_) external onlyOwner {
        _setSpread(spread_);
    }


    function getRate(uint256 id) public view returns (uint256) {
        IBloomPool.TbyMaturity memory maturity = _bloomPool.tbyMaturity(id);
        RwaPrice memory rwaPrice = _tbyIdToRwaPrice[id];

        if (rwaPrice.startPrice == 0) {
            revert Errors.InvalidTby();
        }
        // If the TBY has not started accruing interest, return 1e18.
        if (block.timestamp <= maturity.start) {
            return FpMath.WAD;
        }

        // If the TBY has matured, and is eligible for redemption, calculate the rate based on the end price.
        uint256 price = rwaPrice.endPrice != 0 ? rwaPrice.endPrice : _bloomOracle.getPriceUsd(address(_rwa));
        uint256 rate = (uint256(price).divWad(uint256(rwaPrice.startPrice)));
        return _takeSpread(rate, rwaPrice.spread);
    }

    /// @inheritdoc IBorrowModule
    function spread() external view returns (uint256) {
        return _spread;
    }

    /// @inheritdoc IBorrowModule
    function lastMintedId() external view returns (uint256) {
        return _lastMintedId;
    }

    function tbyCollateral(uint256 id) external view returns (TbyCollateral memory) {
        return _idToCollateral[id];
    }

    function swapBuffer() external view returns (uint256) {
        return _swapBuffer;
    }

    function loanDuration() external view returns (uint256) {
        return _loanDuration;
    }

    /*///////////////////////////////////////////////////////////////
                            Internal Functions    
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal logic to set the leverage.
    function _setLeverage(uint256 leverage) internal {
        require(leverage >= FpMath.WAD && leverage < MAX_LEVERAGE, Errors.InvalidLeverage());
        _leverage = leverage;
        emit LeverageSet(leverage);
    }

    /// @notice Internal logic to set the spread.
    function _setSpread(uint256 spread_) internal {
        require(spread_ >= MIN_SPREAD, Errors.InvalidSpread());
        _spread = spread_;
        emit SpreadSet(spread_);
    }

    /**
     * @notice Takes the spread for the TBY and removes the borrower's interest earned off the yield of the RWA token in order to calculate the TBY rate.
     * @param rate The full rate of the TBY.
     * @param tbySpread The cached spread for the TBY.
     * @return The adjusted rate for the TBY that the lender will earn.
     */
    function _takeSpread(uint256 rate, uint128 tbySpread) internal pure returns (uint256) {
        if (rate > FpMath.WAD) {
            uint256 yield = rate - FpMath.WAD;
            return FpMath.WAD + yield.mulWad(tbySpread);
        }
        return rate;
    }

    /**
     * @notice Purchases the RWA tokens with the underlying asset collateral and stores them within the contract.
     * @dev This function needs to be implemented by the specific protocol that is being used to purchase the RWA tokens.
     *      Integration instructions:
     *         1. Approval has already been set on the BloomPool for the borrow module to spend. This is where the source of funds are coming from.
     *         2. The borrow module will need to swap the underlying asset collateral for the RWA token.
     *         3. RWA token should be held within the borrow module's contract.
     * @param borrower The address of the borrower.
     * @param totalCollateral The total amount of collateral being swapped in.
     * @param rwaPriceUsd The price of the RWA token in USD.
     * @return The amount of RWA tokens purchased.
     */
    function _purchaseRwa(address borrower, uint256 totalCollateral, uint256 rwaPriceUsd)
        internal
        virtual
        returns (uint256)
    {}

    /**
     * @notice Initializes or normalizes the starting price of the TBY.
     * @dev If the TBY Id has already been minted before the start price will be normalized via a time weighted average.
     * @param id The id of the TBY to initialize the start price for.
     * @param currentPrice The current price of the RWA token.
     * @param rwaAmount The amount of rwaAssets that are being swapped in.
     * @param existingCollateral The amount of RWA collateral already in the pool, before the swap, for the TBY id.
     */
    function _setStartPrice(uint256 id, uint256 currentPrice, uint256 rwaAmount, uint256 existingCollateral) private {
        RwaPrice storage rwaPrice = _tbyIdToRwaPrice[id];
        uint256 startPrice = rwaPrice.startPrice;
        if (startPrice == 0) {
            rwaPrice.startPrice = uint128(currentPrice);
            rwaPrice.spread = uint128(_spread);
        } else if (startPrice != currentPrice) {
            rwaPrice.startPrice = uint128(_normalizePrice(startPrice, currentPrice, rwaAmount, existingCollateral));
        }
    }

    /**
     * @notice Normalizes the price of the RWA by taking the weighted average of the startPrice and the currentPrice
     * @dev This is done n the event that the market maker is doing multiple swaps for the same TBY Id,
     *      and the rwa price has changes. We need to recalculate the starting price of the TBY,
     *      to ensure accuracy in the TBY's rate of return.
     * @param startPrice The starting price of the RWA, before the swap.
     * @param currentPrice The Current price of the RWA token.
     * @param amount The amount of RWA tokens being swapped in.
     * @param existingCollateral The existing RWA collateral in the pool, before the swap, for the TBY id.
     */
    function _normalizePrice(uint256 startPrice, uint256 currentPrice, uint256 amount, uint256 existingCollateral)
        private
        pure
        returns (uint128)
    {
        uint256 totalValue = (existingCollateral.mulWad(startPrice) + amount.mulWad(currentPrice));
        uint256 totalCollateral = existingCollateral + amount;
        return uint128(totalValue.divWad(totalCollateral));
    }

    /**
     * @notice Repays the RWA tokens to the issuer in exchange for the underlying asset collateral.
     * @dev This function needs to be implemented by the specific protocol that is being used to repay the RWA tokens.
     *      Integration instructions:
     *         1. Approval has already been set on the BloomPool for the borrow module to spend. This is where the source of funds are coming from.
     *         2. The borrow module will need to swap the RWA token for the underlying asset collateral.
     *         3. RWA token should be held within the borrow module's contract.
     * @param borrower The address of the borrower.
     * @param totalCollateral The total amount of collateral being swapped in.
     * @param rwaPriceUsd The price of the RWA token in USD.
     * @return The amount of RWA tokens purchased.
     */
    function _repayRwa(uint256 amount) internal virtual returns (uint256) {}

    /**
     * @notice Returns the amount of RWA tokens that are being swapped out of the pool.
     * @dev The out of the box implementation returns all of the RWA tokens that are currently held within the contract.
     *      Depending on the specific protocol that is being used to purchase the RWA tokens, this function may need to be overridden.
     * @param tbyId The id of the TBY to get the RWA swap amount for.
     * @return The amount of RWA tokens being swapped out.
     */
    function _getRwaSwapAmount(uint256 tbyId) internal virtual returns (uint256) {
        return _idToCollateral[tbyId].currentRwaAmount;
    }
}
