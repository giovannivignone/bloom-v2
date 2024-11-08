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

    /// @notice The last TBY id that was minted associated with the borrow module.
    uint256 internal _lastMintedId;

    /// @notice Mapping of borrower addresses to their KYC status.
    mapping(address => bool) internal _borrowers;

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

    /// @notice The buffer time between the first minted token of a given TBY id
    ///         and the last possible swap in for that tokenId.
    uint256 constant SWAP_BUFFER = 48 hours;

    /// @notice The default length of time that TBYs mature.
    uint256 constant DEFAULT_MATURITY = 180 days;

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

        uint256 assetDecimals = IERC20Metadata(asset_).decimals();
        uint256 rwaDecimals = IERC20Metadata(rwa_).decimals();

        _assetScalingFactor = rwaDecimals >= assetDecimals ? 10 ** (rwaDecimals - assetDecimals) : (assetDecimals - rwaDecimals);

        _setLeverage(initLeverage);
        _setSpread(initSpread);

        _swapBuffer = SWAP_BUFFER;
        _loanDuration = DEFAULT_MATURITY;
        _lastMintedId = type(uint256).max;
    }

    /*///////////////////////////////////////////////////////////////
                            External Functions    
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBorrowModule
    function borrow(address borrower, uint256 amount)
        external
        override
        onlyBloomPool
        KycBorrower(borrower)
        returns (uint256 bCollateral)
    {
        bCollateral = amount.divWadUp(_leverage);
        require(bCollateral > 0, Errors.ZeroAmount());

        uint256 totalCollateral = _getCollateral(borrower, amount, bCollateral);
        uint256 rwaAmount = _bloomOracle.getQuote(totalCollateral, address(_asset), address(_rwa));
        rwaAmount = _purchaseRwa(borrower, totalCollateral, rwaAmount);

        TbyCollateral storage collateral = _idToCollateral[_lastMintedId];
        collateral.rwaAmount += uint128(rwaAmount);

        uint256 rwaPriceFixedPoint = (totalCollateral * _assetScalingFactor).divWad(rwaAmount);
        _setStartPrice(_lastMintedId, rwaPriceFixedPoint, rwaAmount, collateral.rwaAmount);
    }

    /// @inheritdoc IBorrowModule
    function repay(uint256 tbyId, address borrower)
        external
        override
        onlyBloomPool
        KycBorrower(borrower)
        returns (uint256 lenderReturn, uint256 borrowerReturn, bool isRedeemable)
    {
        uint256 rwaAmount = _getRwaSwapAmount(tbyId);
        require(rwaAmount > 0, Errors.ZeroAmount());

        TbyCollateral storage collateral = _idToCollateral[tbyId];
        // Cannot swap out more RWA tokens than is allocated for the TBY.
        rwaAmount = FpMath.min(rwaAmount, collateral.rwaAmount);

        uint256 assetAmount = _repayRwa(rwaAmount);

        collateral.rwaAmount -= uint128(rwaAmount);
        collateral.assetAmount += uint128(assetAmount);

        if (collateral.rwaAmount == 0) {
            RwaPrice storage rwaPrice_ = _tbyIdToRwaPrice[tbyId];

            isRedeemable = true;
            assetAmount = collateral.assetAmount;
            uint256 tbyAmount = _tby.totalSupply(tbyId);
            lenderReturn = getRate(tbyId).mulWad(tbyAmount);

            if (lenderReturn > assetAmount) {
                uint256 newRate = assetAmount.divWad(tbyAmount);
                uint256 adjustedRate = _takeSpread(newRate, rwaPrice_.spread);
                rwaPrice_.endPrice = uint128(adjustedRate.mulWad(rwaPrice_.startPrice));
                lenderReturn = adjustedRate.mulWad(tbyAmount);
            }

            borrowerReturn = assetAmount - lenderReturn;
        }
    }

    /// @inheritdoc IBorrowModule
    function transferCollateral(uint256 tbyId, uint256 amount, address recipient) external override onlyBloomPool {
        _idToCollateral[tbyId].assetAmount -= uint128(amount);
        IERC20(_asset).safeTransfer(recipient, amount);
    }

    /// @inheritdoc IBorrowModule
    function setLastMintedId(uint256 id) external override onlyBloomPool {
        _lastMintedId = id;
    }

    /*///////////////////////////////////////////////////////////////
                            Admin Functions    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the buffer time between the first and last borrow operation for a tbyId grouping.
     * @dev Only the owner of the module can call this function.
     * @param buffer The new buffer time.
     */
    function setSwapBuffer(uint256 buffer) external onlyOwner {
        _swapBuffer = buffer;
    }

    /**
     * @notice Sets the duration of the loan for the next minted TBY.
     * @dev Only the owner of the module can call this function.
     * @param duration The new duration of the loan.
     */
    function setLoanDuration(uint256 duration) external onlyOwner {
        _loanDuration = duration;
    }

    /**
     * @notice Updates the leverage for future borrower fills
     * @dev Leverage is scaled to 1e18. (20x leverage = 20e18)
     * @param leverage_ The new leverage value.
     */
    function setLeverage(uint256 leverage_) external onlyOwner {
        _setLeverage(leverage_);
    }

    /**
     * @notice Updates the spread between the TBY rate and the RWA rate.
     * @param spread_ The new spread value.
     */
    function setSpread(uint256 spread_) external onlyOwner {
        _setSpread(spread_);
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
                            Internal Functions    
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal logic to set the leverage.
    function _setLeverage(uint256 leverage_) internal {
        require(leverage_ >= FpMath.WAD && leverage_ < MAX_LEVERAGE, Errors.InvalidLeverage());
        _leverage = leverage_;
        emit LeverageSet(leverage_);
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
     * @notice Initializes or normalizes the starting price of the TBY.
     * @dev If the TBY Id has already been minted before the start price will be normalized via a time weighted average.
     * @param id The id of the TBY to initialize the start price for.
     * @param currentPrice The current price of the RWA token.
     * @param rwaAmount The amount of rwaAssets that are being swapped in.
     * @param existingCollateral The amount of RWA collateral already in the pool, before the swap, for the TBY id.
     */
    function _setStartPrice(uint256 id, uint256 currentPrice, uint256 rwaAmount, uint256 existingCollateral) private {
        RwaPrice storage rwaPrice_ = _tbyIdToRwaPrice[id];
        uint256 startPrice = rwaPrice_.startPrice;
        if (startPrice == 0) {
            rwaPrice_.startPrice = uint128(currentPrice);
            rwaPrice_.spread = uint128(_spread);
        } else if (startPrice != currentPrice) {
            rwaPrice_.startPrice = uint128(_normalizePrice(startPrice, currentPrice, rwaAmount, existingCollateral));
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

    function _getCollateral(address borrower, uint256 amount, uint256 bCollateral) internal returns (uint256) {
        IERC20(_asset).transferFrom(borrower, address(this), bCollateral);
        IERC20(_asset).transferFrom(address(_bloomPool), address(this), amount);
        return amount + bCollateral;
    }

    /*///////////////////////////////////////////////////////////////
                            View Functions    
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBorrowModule
    function getRate(uint256 id) public view override returns (uint256) {
        IBloomPool.TbyMaturity memory maturity = _bloomPool.tbyMaturity(id);
        RwaPrice memory rwaPrice_ = _tbyIdToRwaPrice[id];

        if (rwaPrice_.startPrice == 0) {
            revert Errors.InvalidTby();
        }
        // If the TBY has not started accruing interest, return 1e18.
        if (block.timestamp <= maturity.start) {
            return FpMath.WAD;
        }

        // If the TBY has matured, and is eligible for redemption, calculate the rate based on the end price.
        uint256 price = rwaPrice_.endPrice != 0
            ? rwaPrice_.endPrice
            : _bloomOracle.getQuote(10 ** IERC20Metadata(address(_rwa)).decimals(), address(_asset), address(_rwa));
        uint256 rate = (uint256(price).divWad(uint256(rwaPrice_.startPrice)));
        return _takeSpread(rate, rwaPrice_.spread);
    }

    /// @inheritdoc IBorrowModule
    function bloomPool() external view override returns (address) {
        return address(_bloomPool);
    }

    /// @inheritdoc IBorrowModule
    function tby() external view override returns (address) {
        return address(_tby);
    }

    /// @inheritdoc IBorrowModule
    function asset() external view override returns (address) {
        return address(_asset);
    }

    /// @inheritdoc IBorrowModule
    function rwa() external view override returns (address) {
        return address(_rwa);
    }

    /// @inheritdoc IBorrowModule
    function bloomOracle() external view override returns (address) {
        return address(_bloomOracle);
    }

    /// @inheritdoc IBorrowModule
    function leverage() external view override returns (uint256) {
        return _leverage;
    }

    /// @inheritdoc IBorrowModule
    function spread() external view override returns (uint256) {
        return _spread;
    }

    /// @inheritdoc IBorrowModule
    function swapBuffer() external view override returns (uint256) {
        return _swapBuffer;
    }

    /// @inheritdoc IBorrowModule
    function loanDuration() external view override returns (uint256) {
        return _loanDuration;
    }

    /// @inheritdoc IBorrowModule
    function lastMintedId() external view override returns (uint256) {
        return _lastMintedId;
    }

    /// @inheritdoc IBorrowModule
    function isKYCedBorrower(address account) public view override returns (bool) {
        return _borrowers[account];
    }

    /// @inheritdoc IBorrowModule
    function rwaPrice(uint256 id) external view override returns (RwaPrice memory) {
        return _tbyIdToRwaPrice[id];
    }

    /// @inheritdoc IBorrowModule
    function tbyCollateral(uint256 id) external view override returns (TbyCollateral memory) {
        return _idToCollateral[id];
    }

    /*///////////////////////////////////////////////////////////////
                            Virtual Functions    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Purchases the RWA tokens with the underlying asset collateral and stores them within the contract.
     * @dev This function needs to be implemented by the specific protocol that is being used to purchase the RWA tokens.
     *      Integration instructions:
     *         1. Approval has already been set on the BloomPool for the borrow module to spend. This is where the source of funds are coming from.
     *         2. The borrow module will need to swap the underlying asset collateral for the RWA token.
     *         3. RWA token should be held within the borrow module's contract.
     * @param borrower The address of the borrower.
     * @param totalCollateral The total amount of collateral being swapped in.
     * @param rwaAmount The amount of RWA tokens purchased.
     * @return The amount of RWA tokens purchased.
     */
    function _purchaseRwa(address borrower, uint256 totalCollateral, uint256 rwaAmount)
        internal
        virtual
        returns (uint256)
    {}

    /**
     * @notice Repays the RWA tokens to the issuer in exchange for the underlying asset collateral.
     * @dev This function needs to be implemented by the specific protocol that is being used to repay the RWA tokens.
     *      Integration instructions:
     *         1. Source of funds are coming from the Borrow Module.
     *         2. The borrow module will need to swap the RWA token for the underlying asset collateral.
     *         3. Underlying asset should be held within the borrow module's contract.
     * @param amount The amount of RWA tokens being repaid.
     * @return The amount of underlying asset collateral being received.
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
        return _idToCollateral[tbyId].rwaAmount;
    }
}
