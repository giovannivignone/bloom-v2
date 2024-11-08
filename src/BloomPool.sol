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

import {FixedPointMathLib as FpMath} from "@solady/utils/FixedPointMathLib.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@solady/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BloomErrors as Errors} from "@bloom-v2/helpers/BloomErrors.sol";

import {Tby} from "@bloom-v2/token/Tby.sol";
import {IBorrowModule} from "@bloom-v2/interfaces/IBorrowModule.sol";
import {IBloomPool} from "@bloom-v2/interfaces/IBloomPool.sol";

/**
 * @title BloomPool
 * @notice An RFQ protocol for permissionlessly being able to access RWA yield by connecting lenders to compliant borrowers.
 */
contract BloomPool is IBloomPool, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using FpMath for uint256;

    /*///////////////////////////////////////////////////////////////
                                Storage    
    //////////////////////////////////////////////////////////////*/

    /// @notice Current total depth of unfilled orders.
    uint256 private _openDepth;

    /// @notice The last TBY id that was minted.
    uint256 private _lastMintedId;

    /// @notice Mapping of users to their open order amount.
    mapping(address => uint256) private _userOpenOrder;

    /// @notice Mapping of borrow module addresses to whether they are active.
    mapping(address => bool) internal _borrowModules;

    /// @notice Mapping of TBY ids to their corresponding borrow module.
    mapping(uint256 => address) internal _tbyModule;

    /// @notice Mapping of TBY ids to the maturity range.
    mapping(uint256 => TbyMaturity) private _idToMaturity;

    /// @notice Mapping of borrowers to the amount they have borrowed for a given TBY id.
    mapping(address => mapping(uint256 => uint256)) private _borrowerAmounts;

    /// @notice Mapping of TBY ids to the total amount borrowed.
    mapping(uint256 => uint256) private _idToTotalBorrowed;

    /// @notice Mapping of TBY ids to whether they are redeemable.
    mapping(uint256 => bool) private _isTbyRedeemable;

    /// @notice Mapping of TBY ids to the lender returns.
    mapping(uint256 => uint256) private _tbyLenderReturns;

    /// @notice Mapping of TBY ids to the borrower returns.
    mapping(uint256 => uint256) private _tbyBorrowerReturns;

    /*///////////////////////////////////////////////////////////////
                        Constants & Immutables
    //////////////////////////////////////////////////////////////*/

    /// @notice Instance of the Tby token.
    Tby internal immutable _tby;

    /// @notice Address of the underlying asset of the Pool.
    address internal immutable _asset;

    /// @notice Decimals of the underlying asset of the Pool.
    uint8 internal immutable _assetDecimals;

    /// @notice The minimum size of an order.
    uint256 internal immutable _minOrderSize;

    /*///////////////////////////////////////////////////////////////
                            Modifiers    
    //////////////////////////////////////////////////////////////*/

    modifier validModule(address module) {
        if (!_borrowModules[module]) revert Errors.InvalidBorrowModule();
        _;
    }

    modifier isRedeemable(uint256 id) {
        require(_isTbyRedeemable[id], Errors.TBYNotRedeemable());
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            Constructor    
    //////////////////////////////////////////////////////////////*/

    constructor(address asset_, address owner_) Ownable(owner_) {
        _asset = asset_;

        uint8 decimals = IERC20Metadata(asset_).decimals();
        _tby = new Tby(address(this), decimals);

        _assetDecimals = decimals;
        _minOrderSize = 10 ** decimals; // Minimum order size is 1 underlying asset.
        _lastMintedId = type(uint256).max;
    }

    /*///////////////////////////////////////////////////////////////
                            Functions    
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBloomPool
    function lendOrder(uint256 amount) external override {
        _amountZeroCheck(amount);
        _minOrderSizeCheck(amount);
        _openOrder(msg.sender, amount);
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IBloomPool
    function borrow(address[] memory lenders, address module, uint256 amount)
        external
        override
        validModule(module)
        nonReentrant
        returns (uint256 tbyId, uint256 lCollateral, uint256 bCollateral)
    {
        tbyId = _handleTbyId(module);
        _tbyModule[tbyId] = module;

        uint256 len = lenders.length;
        for (uint256 i = 0; i != len; ++i) {
            lCollateral += _fillOrder(lenders[i], tbyId, amount);
        }

        IERC20(_asset).forceApprove(module, lCollateral);
        bCollateral = IBorrowModule(module).borrow(msg.sender, lCollateral);
        _borrowerAmounts[msg.sender][tbyId] += bCollateral;
        _idToTotalBorrowed[tbyId] += bCollateral;
    }

    /// @inheritdoc IBloomPool
    function repay(uint256 tbyId) external override nonReentrant {
        address module = _tbyModule[tbyId];
        require(module != address(0), Errors.InvalidTby());
        require(_idToMaturity[tbyId].end <= block.timestamp, Errors.TBYNotMatured());
        (uint256 lenderReturn, uint256 borrowerReturn, bool redeemable) = IBorrowModule(module).repay(tbyId, msg.sender);

        if (redeemable) {
            _isTbyRedeemable[tbyId] = true;
            _tbyLenderReturns[tbyId] += lenderReturn;
            _tbyBorrowerReturns[tbyId] += borrowerReturn;
        }
    }

    /// @inheritdoc IBloomPool
    function redeemLender(uint256 tbyId, uint256 amount)
        external
        override
        isRedeemable(tbyId)
        returns (uint256 reward)
    {
        require(_tby.balanceOf(msg.sender, tbyId) >= amount, Errors.InsufficientBalance());

        uint256 totalSupply = _tby.totalSupply(tbyId);
        reward = (_tbyLenderReturns[tbyId] * amount) / totalSupply;
        require(reward > 0, Errors.ZeroRewards());

        _tbyLenderReturns[tbyId] -= reward;
        _tby.burn(tbyId, msg.sender, amount);

        emit LenderRedeemed(msg.sender, tbyId, reward);

        IBorrowModule module = IBorrowModule(_tbyModule[tbyId]);
        module.transferCollateral(tbyId, reward, msg.sender); // Send tokens to the lender
    }

    /// @inheritdoc IBloomPool
    function redeemBorrower(uint256 tbyId) external override isRedeemable(tbyId) returns (uint256 reward) {
        uint256 totalBorrowAmount = _idToTotalBorrowed[tbyId];
        uint256 borrowAmount = _borrowerAmounts[msg.sender][tbyId];
        require(totalBorrowAmount != 0, Errors.TotalBorrowedZero());

        reward = (_tbyBorrowerReturns[tbyId] * borrowAmount) / totalBorrowAmount;
        require(reward > 0, Errors.ZeroRewards());

        _tbyBorrowerReturns[tbyId] -= reward;
        _borrowerAmounts[msg.sender][tbyId] -= borrowAmount;
        _idToTotalBorrowed[tbyId] -= borrowAmount;

        emit BorrowerRedeemed(msg.sender, tbyId, reward);

        IBorrowModule module = IBorrowModule(_tbyModule[tbyId]);
        module.transferCollateral(tbyId, reward, msg.sender); // Send tokens to the borrower
    }

    /// @inheritdoc IBloomPool
    function killOpenOrder(uint256 amount) external override {
        uint256 orderDepth = _userOpenOrder[msg.sender];
        _amountZeroCheck(amount);
        require(amount <= orderDepth, Errors.InsufficientDepth());

        _userOpenOrder[msg.sender] -= amount;
        _openDepth -= amount;

        emit OpenOrderKilled(msg.sender, amount);
        IERC20(_asset).safeTransfer(msg.sender, amount);
    }

    /*///////////////////////////////////////////////////////////////
                            Admin Functions    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a borrow module to the pool.
     * @param module The address of the borrow module to add.
     */
    function addBorrowModule(address module) external onlyOwner {
        _borrowModules[module] = true;
    }

    /**
     * @notice Pauses a borrow module.
     * @dev Pausing a borrow module prevents new borrows from being created, but does not affect the ability to repay existing borrows.
     * @param module The address of the borrow module to pause.
     */
    function pauseBorrowModule(address module) external onlyOwner {
        _borrowModules[module] = false;
    }

    /*///////////////////////////////////////////////////////////////
                            Internal Functions    
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fills an order with a specified amount of underlying assets
     * @param account The address of the order to fill
     * @param amount Amount of underlying assets of the order to fill
     */
    function _fillOrder(address account, uint256 tbyId, uint256 amount) internal returns (uint256 lCollateral) {
        require(account != address(0), Errors.ZeroAddress());
        _amountZeroCheck(amount);

        uint256 orderDepth = _userOpenOrder[account];

        lCollateral = FpMath.min(orderDepth, amount);
        _openDepth -= lCollateral;
        orderDepth -= lCollateral;

        if (orderDepth != 0) {
            _minOrderSizeCheck(orderDepth);
        }

        _userOpenOrder[account] = orderDepth;
        _tby.mint(tbyId, account, lCollateral);
    }

    /**
     * @notice Opens an order for the lender
     * @param lender The address of the lender
     * @param amount The amount of underlying assets to open the order
     */
    function _openOrder(address lender, uint256 amount) internal {
        _openDepth += amount;
        _userOpenOrder[lender] += amount;
        emit OrderCreated(lender, amount);
    }

    /**
     * @notice Checks if the amount is greater than zero
     * @param amount The amount of underlying assets to close the matched order
     */
    function _amountZeroCheck(uint256 amount) internal pure {
        require(amount > 0, Errors.ZeroAmount());
    }

    /**
     * @notice Checks if an amount is greater than the minimum order size
     * @param amount The amount of underlying assets to check
     */
    function _minOrderSizeCheck(uint256 amount) internal view {
        require(amount >= _minOrderSize, Errors.OrderBelowMinSize());
    }

    /**
     * @notice Calculates the TBY id to mint based on the last minted TBY id and the swap buffer.
     * @dev If the last minted TBY id was created 48 hours ago or more, a new TBY id is minted.
     * @return id The id of the TBY to mint.
     */
    function _handleTbyId(address module) private returns (uint256 id) {
        // Get the last minted TBY id from the borrow module
        id = IBorrowModule(module).lastMintedId();
        TbyMaturity memory maturity = _idToMaturity[id];

        // If the timestamp of the last minted TBYs start is greater than 48 hours from now, this swap is for a new TBY Id.
        if (block.timestamp > maturity.start + IBorrowModule(module).swapBuffer()) {
            // Last minted id is set to type(uint256).max, so we need to wrap around to 0 to start the first TBY.
            unchecked {
                id = ++_lastMintedId;
            }
            uint128 start = uint128(block.timestamp);
            uint128 end = start + uint128(IBorrowModule(module).loanDuration());
            _idToMaturity[id] = TbyMaturity(start, end);

            IBorrowModule(module).setLastMintedId(id);
        }
    }

    /*///////////////////////////////////////////////////////////////
                            View Functions    
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBloomPool
    function tby() external view override returns (address) {
        return address(_tby);
    }

    /// @inheritdoc IBloomPool
    function asset() external view override returns (address) {
        return _asset;
    }

    /// @inheritdoc IBloomPool
    function assetDecimals() external view override returns (uint8) {
        return _assetDecimals;
    }

    /// @inheritdoc IBloomPool
    function openDepth() external view override returns (uint256) {
        return _openDepth;
    }

    /// @inheritdoc IBloomPool
    function amountOpen(address account) external view override returns (uint256) {
        return _userOpenOrder[account];
    }

    /// @inheritdoc IBloomPool
    function minOrderSize() external view override returns (uint256) {
        return _minOrderSize;
    }

    /// @inheritdoc IBloomPool
    function lastMintedId() external view override returns (uint256) {
        return _lastMintedId;
    }

    /// @inheritdoc IBloomPool
    function tbyMaturity(uint256 id) external view override returns (TbyMaturity memory) {
        return _idToMaturity[id];
    }

    /// @inheritdoc IBloomPool
    function borrowerAmount(address account, uint256 id) external view override returns (uint256) {
        return _borrowerAmounts[account][id];
    }

    /// @inheritdoc IBloomPool
    function totalBorrowed(uint256 id) external view override returns (uint256) {
        return _idToTotalBorrowed[id];
    }

    /// @inheritdoc IBloomPool
    function isTbyRedeemable(uint256 id) external view override returns (bool) {
        return _isTbyRedeemable[id];
    }

    /// @inheritdoc IBloomPool
    function lenderReturns(uint256 tbyId) external view override returns (uint256) {
        return _tbyLenderReturns[tbyId];
    }

    /// @inheritdoc IBloomPool
    function borrowerReturns(uint256 tbyId) external view override returns (uint256) {
        return _tbyBorrowerReturns[tbyId];
    }
}
