// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IMoreMarkets, Market, Id, MarketParams, Position} from "./interfaces/IMoreMarkets.sol";
import {IMoreVaults} from "./interfaces/IMoreVaults.sol";
import {ILiquidTokenStakingPool} from "./interfaces/ILiquidTokenStakingPool.sol";
import {ICertificateToken} from "./interfaces/ICertificateToken.sol";
import {ITradoSwap} from "./interfaces/ITradoSwap.sol";
import {IProtocolFeeManager} from "./interfaces/IProtocolFeeManager.sol";
import {ILoopStrategy, IERC20Metadata} from "./interfaces/ILoopStrategy.sol";

import {MathLib, WAD} from "./libraries/MathLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";

import {MulticallUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IERC4626, ERC4626Upgradeable, Math, SafeERC20, IERC20, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Bytes} from "@openzeppelin/contracts/utils/Bytes.sol";

import {IWNative} from "./interfaces/IWNative.sol";

contract LoopStrategy is
    ILoopStrategy,
    ERC4626Upgradeable,
    ERC20PermitUpgradeable,
    Ownable2StepUpgradeable,
    MulticallUpgradeable,
    ReentrancyGuardUpgradeable
{
    using MathLib for uint128;
    using MathLib for uint256;
    using Math for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using Bytes for bytes;

    /// @inheritdoc ILoopStrategy
    IMoreMarkets public markets;
    /// @inheritdoc ILoopStrategy
    ILiquidTokenStakingPool public staking;
    /// @inheritdoc ILoopStrategy
    IMoreVaults public vault;
    /// @inheritdoc ILoopStrategy
    ITradoSwap public router;
    /// @inheritdoc ILoopStrategy
    Id public marketId;
    /// @inheritdoc ILoopStrategy
    address public ankrFlow;
    /// @inheritdoc ILoopStrategy
    address public wFlow;

    /// @inheritdoc ILoopStrategy
    uint256 public targetUtilization;
    /// @inheritdoc ILoopStrategy
    uint256 public targetStrategyLtv;
    /// @inheritdoc ILoopStrategy
    uint256 public swapMaxLossPercent;

    /// @inheritdoc ILoopStrategy
    bytes public defaultPath;

    /// @inheritdoc ILoopStrategy
    address public feeRecipient;
    /// @inheritdoc ILoopStrategy
    uint96 public fee;
    /// @inheritdoc ILoopStrategy
    address public protocolFeeManager;
    /// @inheritdoc ILoopStrategy
    uint256 public lastTotalAssets;

    /// @dev Market parameters
    MarketParams internal _marketParams;

    /// @dev Maximum allowed fee (50%, expressed as 0.5e18).
    uint256 internal constant MAX_FEE = 0.5e18;

    /// @notice Emitted when the target utilization is exceeded.
    error TargetUtilizationReached();
    /// @notice Emitted when an attempt is made to set a value that is already set.
    error AlreadySet();
    /// @notice Emitted when a fee exceeds the maximum allowed value.
    error MaxFeeExceeded();
    /// @notice Emitted when the fee recipient address is zero.
    error ZeroFeeRecipient();
    /// @notice Emitted when the caller is unauthorized.
    error Unauthorized();
    /// @notice Emitted when the path is invalid, tokenIn should be wFlow and tokenOut ankrFlow.
    error InvalidPath();

    /// @inheritdoc ILoopStrategy
    function initialize(
        address owner,
        address moreMarkets,
        address _vault,
        address _staking,
        address _asset,
        address _ankrFlow,
        address _router,
        Id _marketId,
        uint256 _targetUtilization,
        uint256 _targetStrategyLtv,
        uint256 _swapMaxLossPercent,
        address _protocolFeeManager,
        string memory _name,
        string memory _symbol
    ) external initializer {
        __ERC4626_init(IERC20(_asset));
        __ERC20Permit_init(_name);
        __ERC20_init(_name, _symbol);
        __Ownable_init(owner);
        _transferOwnership(owner);
        __ReentrancyGuard_init();

        markets = IMoreMarkets(moreMarkets);
        staking = ILiquidTokenStakingPool(_staking);
        vault = IMoreVaults(_vault);
        router = ITradoSwap(_router);
        ankrFlow = _ankrFlow;
        wFlow = _asset;
        marketId = _marketId;
        targetUtilization = _targetUtilization;
        targetStrategyLtv = _targetStrategyLtv;
        protocolFeeManager = _protocolFeeManager;
        swapMaxLossPercent = _swapMaxLossPercent;

        (
            bool isPrem,
            address loanToken,
            address collateralToken,
            address oracle,
            address irm,
            uint256 lltv,
            address cas,
            uint96 irxMaxLltv,
            uint256[] memory lltvsFromContract
        ) = markets.idToMarketParams(marketId);
        _marketParams = MarketParams(
            isPrem,
            loanToken,
            collateralToken,
            oracle,
            irm,
            lltv,
            cas,
            irxMaxLltv,
            lltvsFromContract
        );

        SafeERC20.forceApprove(
            IERC20(wFlow),
            address(vault),
            type(uint256).max
        );
        SafeERC20.forceApprove(
            IERC20(ankrFlow),
            address(markets),
            type(uint256).max
        );
        SafeERC20.forceApprove(
            IERC20(ankrFlow),
            address(router),
            type(uint256).max
        );

        defaultPath = abi.encodePacked(wFlow, uint24(500), address(ankrFlow));
    }

    /// @dev This function is called when the FLOW token is sent to the contract and
    /// should be wrapped in any cases beside wrap operations.
    receive() external payable {
        if (msg.sender != wFlow) {
            IWNative(wFlow).deposit{value: msg.value}();
        }
    }

    /// @inheritdoc IERC20Metadata
    function decimals()
        public
        view
        override(IERC20Metadata, ERC20Upgradeable, ERC4626Upgradeable)
        returns (uint8)
    {
        return ERC4626Upgradeable.decimals();
    }

    /// @inheritdoc IERC4626
    function asset()
        public
        view
        override(IERC4626, ERC4626Upgradeable)
        returns (address)
    {
        return wFlow;
    }

    /// @inheritdoc IERC4626
    function totalAssets()
        public
        view
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256)
    {
        Position memory position = markets.position(marketId, address(this));
        uint256 totalBorrowSharesForMultiplier = markets
            .totalBorrowSharesForMultiplier(marketId, position.lastMultiplier);
        uint256 totalBorrowAssetsForMultiplier = markets
            .totalBorrowAssetsForMultiplier(marketId, position.lastMultiplier);

        uint256 borrowedAssets = position.borrowShares > 0
            ? uint256(position.borrowShares).toAssetsUp(
                totalBorrowAssetsForMultiplier,
                totalBorrowSharesForMultiplier
            )
            : 0;

        // total assets = vault balance in wFLOW(supplied to vault + balanceOf contract) + collateral balance in wFLOW - borrowed assets
        uint256 _totalAssets = vault.convertToAssets(
            vault.balanceOf(address(this))
        ) +
            ICertificateToken(ankrFlow).sharesToBonds(position.collateral) -
            borrowedAssets +
            IWNative(wFlow).balanceOf(address(this));

        return _totalAssets;
    }

    /// @inheritdoc IERC4626
    function maxDeposit(
        address
    ) public view override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        return _maxDeposit();
    }

    /// @inheritdoc IERC4626
    function maxMint(
        address
    ) public view override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        uint256 suppliable = _maxDeposit();

        return _convertToShares(suppliable, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(
        address owner
    )
        public
        view
        override(IERC4626, ERC4626Upgradeable)
        returns (uint256 assets)
    {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
        uint256 newTotalSupply = totalSupply() + feeShares;

        assets = _convertToAssetsWithTotals(
            balanceOf(owner),
            newTotalSupply,
            newTotalAssets,
            Math.Rounding.Floor
        );
    }

    /// @notice Calculates the expected amount to repay the loan debt corresponding to the `assets`
    /// value provided, and calculates and returns the amount of `wFlow` and `ankrFlow` to be received.
    /// @param assets The amount of assets to withdraw.
    /// @return amountToRepay The amount of debt to repay.
    /// @return wFlowAmount The amount of `wFlow` to receive.
    /// @return ankrFlowAmount The amount of `ankrFlow` to receive.
    function expectedAmountsToWithdraw(
        uint256 assets
    )
        external
        view
        returns (
            uint256 amountToRepay,
            uint256 wFlowAmount,
            uint256 ankrFlowAmount
        )
    {
        uint256 percentage = _calculatePercentage(assets);

        Position memory position = markets.position(marketId, address(this));
        ankrFlowAmount = position.collateral.wMulDown(percentage);
        uint256 sharesToRepay = position.borrowShares.wMulDown(percentage);

        uint256 totalBorrowSharesForMultiplier = markets
            .totalBorrowSharesForMultiplier(marketId, position.lastMultiplier);
        uint256 totalBorrowAssetsForMultiplier = markets
            .totalBorrowAssetsForMultiplier(marketId, position.lastMultiplier);

        amountToRepay = sharesToRepay.toAssetsUp(
            totalBorrowAssetsForMultiplier,
            totalBorrowSharesForMultiplier
        );

        uint256 sharesToWithdraw = vault.balanceOf(address(this)).wMulDown(
            percentage
        );
        wFlowAmount = vault.previewRedeem(sharesToWithdraw);
    }

    /// @inheritdoc ILoopStrategy
    function setFee(uint256 newFee) external onlyOwner {
        if (newFee == fee) revert AlreadySet();
        if (newFee > MAX_FEE) revert MaxFeeExceeded();
        if (newFee != 0 && feeRecipient == address(0))
            revert ZeroFeeRecipient();

        // Accrue fee using the previous fee set before changing it.
        _updateLastTotalAssets(_accrueFee());

        // Safe "unchecked" cast because newFee <= MAX_FEE.
        fee = uint96(newFee);

        emit SetFee(_msgSender(), fee);
    }

    /// @inheritdoc ILoopStrategy
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == feeRecipient) revert AlreadySet();
        if (newFeeRecipient == address(0) && fee != 0)
            revert ZeroFeeRecipient();

        // Accrue fee to the previous fee recipient set before changing it.
        _updateLastTotalAssets(_accrueFee());

        feeRecipient = newFeeRecipient;

        emit SetFeeRecipient(newFeeRecipient);
    }

    /// @inheritdoc ILoopStrategy
    function setSwapMaxLossPercent(
        uint256 _swapMaxLossPercent
    ) external onlyOwner {
        if (swapMaxLossPercent == _swapMaxLossPercent) revert AlreadySet();

        swapMaxLossPercent = _swapMaxLossPercent;
        emit SetSwapMaxLossPercent(swapMaxLossPercent);
    }

    /// @inheritdoc ILoopStrategy
    function setTargetUtilization(
        uint256 _newTargetUtilization
    ) external onlyOwner {
        if (targetUtilization == _newTargetUtilization) revert AlreadySet();

        targetUtilization = _newTargetUtilization;
        emit SetTargetUtilization(_newTargetUtilization);
    }

    /// @inheritdoc IERC4626
    function deposit(
        uint256 assets,
        address receiver
    ) public override(IERC4626, ERC4626Upgradeable) returns (uint256 shares) {
        markets.accrueInterest(_marketParams);
        uint256 newTotalAssets = _accrueFee();

        // Update `lastTotalAssets` to avoid an inconsistent state in a re-entrant context.
        // It is updated again in `_deposit`.
        lastTotalAssets = newTotalAssets;

        shares = _convertToSharesWithTotals(
            assets,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Floor
        );

        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @inheritdoc IERC4626
    function mint(
        uint256 shares,
        address receiver
    ) public override(IERC4626, ERC4626Upgradeable) returns (uint256 assets) {
        markets.accrueInterest(_marketParams);
        uint256 newTotalAssets = _accrueFee();

        // Update `lastTotalAssets` to avoid an inconsistent state in a re-entrant context.
        // It is updated again in `_deposit`.
        lastTotalAssets = newTotalAssets;

        assets = _convertToAssetsWithTotals(
            shares,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Ceil
        );

        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @inheritdoc ILoopStrategy
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        bytes memory path
    ) public returns (uint256 shares) {
        markets.accrueInterest(_marketParams);
        uint256 newTotalAssets = _accrueFee();

        // Do not call expensive `maxWithdraw` and optimistically withdraw assets.

        shares = _convertToSharesWithTotals(
            assets,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Ceil
        );

        // `newTotalAssets - assets` may be a little off from `totalAssets()`.
        _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

        _withdraw(_msgSender(), receiver, owner, assets, shares, path);
    }

    /// @inheritdoc ILoopStrategy
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        bytes memory path
    ) public returns (uint256 assets) {
        markets.accrueInterest(_marketParams);
        uint256 newTotalAssets = _accrueFee();

        // Do not call expensive `maxRedeem` and optimistically redeem shares.

        assets = _convertToAssetsWithTotals(
            shares,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Floor
        );
        _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

        _withdraw(_msgSender(), receiver, owner, assets, shares, path);
    }

    /// @inheritdoc IERC4626
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override(IERC4626, ERC4626Upgradeable) returns (uint256 shares) {
        markets.accrueInterest(_marketParams);
        uint256 newTotalAssets = _accrueFee();

        // Do not call expensive `maxWithdraw` and optimistically withdraw assets.

        shares = _convertToSharesWithTotals(
            assets,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Ceil
        );
        _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));
        // `newTotalAssets - assets` may be a little off from `totalAssets()`.
        _withdraw(_msgSender(), receiver, owner, assets, shares, defaultPath);
    }

    /// @inheritdoc IERC4626
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override(IERC4626, ERC4626Upgradeable) returns (uint256 assets) {
        markets.accrueInterest(_marketParams);
        uint256 newTotalAssets = _accrueFee();

        // Do not call expensive `maxRedeem` and optimistically redeem shares.

        assets = _convertToAssetsWithTotals(
            shares,
            totalSupply(),
            newTotalAssets,
            Math.Rounding.Floor
        );
        _updateLastTotalAssets(newTotalAssets.zeroFloorSub(assets));

        _withdraw(_msgSender(), receiver, owner, assets, shares, defaultPath);
    }

    /**
     * @notice Handles operations during a flash loan initiated through the MoreMarkets protocol.
     * @dev Effectively this function swaps the returned collateral to loan token and repay it.
     *
     * @param assets The amount of assets to repay during the flash loan process.
     * @param data Encoded data containing repayment shares, collateral details, assets to withdraw,
     *             receiver address, market parameters, and the swap path.
     *
     * @dev This function interacts with both the MoreMarkets protocol and the TradoSwap router.
     * @dev Reverts if the swap fails or the resulting amounts are insufficient to complete the process.
     */
    function onMoreFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(markets)) revert Unauthorized();
        (
            uint256 sharesToRepay,
            uint256 collateralToWithdraw,
            uint256 assetsToWithdraw,
            address receiver,
            bytes memory path
        ) = abi.decode(data, (uint256, uint256, uint256, address, bytes));

        SafeERC20.forceApprove(IERC20(wFlow), address(markets), assets);
        markets.repay(_marketParams, 0, sharesToRepay, address(this), "");
        SafeERC20.forceApprove(IERC20(wFlow), address(markets), 0);
        markets.withdrawCollateral(
            _marketParams,
            collateralToWithdraw,
            address(this),
            address(this)
        );

        uint256 maxPayed = ICertificateToken(ankrFlow).bondsToShares(assets) +
            assetsToWithdraw.wMulDown(swapMaxLossPercent);

        ITradoSwap.SwapDesireParams memory swapDesireParams = ITradoSwap
            .SwapDesireParams({
                path: path,
                recipient: address(this),
                desire: uint128(assets),
                maxPayed: maxPayed,
                outFee: 0,
                deadline: block.timestamp
            });
        (uint256 cost, ) = router.swapDesire(swapDesireParams);

        SafeERC20.safeTransfer(
            IERC20(ankrFlow),
            receiver,
            collateralToWithdraw - cost
        );
        SafeERC20.forceApprove(IERC20(wFlow), address(markets), assets);
    }

    /// @dev Updates `lastTotalAssets` to `updatedTotalAssets`.
    function _updateLastTotalAssets(uint256 updatedTotalAssets) internal {
        lastTotalAssets = updatedTotalAssets;
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev The accrual of performance fees is taken into account in the conversion.
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();

        return
            _convertToSharesWithTotals(
                assets,
                totalSupply() + feeShares,
                newTotalAssets,
                rounding
            );
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev The accrual of performance fees is taken into account in the conversion.
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
        return
            _convertToAssetsWithTotals(
                shares,
                totalSupply() + feeShares,
                newTotalAssets,
                rounding
            );
    }

    /// @dev Returns the amount of shares that the vault would exchange for the amount of `assets` provided.
    /// @dev It assumes that the arguments `newTotalSupply` and `newTotalAssets` are up to date.
    function _convertToSharesWithTotals(
        uint256 assets,
        uint256 newTotalSupply,
        uint256 newTotalAssets,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        return
            assets.mulDiv(
                newTotalSupply + 10 ** _decimalsOffset(),
                newTotalAssets + 1,
                rounding
            );
    }

    /// @dev Returns the amount of assets that the vault would exchange for the amount of `shares` provided.
    /// @dev It assumes that the arguments `newTotalSupply` and `newTotalAssets` are up to date.
    function _convertToAssetsWithTotals(
        uint256 shares,
        uint256 newTotalSupply,
        uint256 newTotalAssets,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        return
            shares.mulDiv(
                newTotalAssets + 1,
                newTotalSupply + 10 ** _decimalsOffset(),
                rounding
            );
    }

    /// @dev Accrues the fee and mints the fee shares to the fee recipient.
    /// @return newTotalAssets The vaults total assets after accruing the interest.
    function _accrueFee() internal returns (uint256 newTotalAssets) {
        uint256 feeShares;
        (feeShares, newTotalAssets) = _accruedFeeShares();

        (
            uint96 protocolFee,
            address protocolFeeRecipient
        ) = IProtocolFeeManager(protocolFeeManager).getProtocolFeeInfo(
                address(this)
            );

        if (feeShares != 0) {
            if (protocolFee != 0) {
                _mint(protocolFeeRecipient, feeShares.wMulDown(protocolFee));
                _mint(feeRecipient, feeShares.wMulDown(WAD - protocolFee));
            } else {
                _mint(feeRecipient, feeShares);
            }
        }

        emit AccrueInterest(newTotalAssets, feeShares);
    }

    /// @dev Computes and returns the fee shares (`feeShares`) to mint and the new vault's total assets
    /// (`newTotalAssets`).
    function _accruedFeeShares()
        internal
        view
        returns (uint256 feeShares, uint256 newTotalAssets)
    {
        newTotalAssets = totalAssets();

        uint256 totalInterest = newTotalAssets.zeroFloorSub(lastTotalAssets);
        if (totalInterest != 0 && fee != 0) {
            // It is acknowledged that `feeAssets` may be rounded down to 0 if `totalInterest * fee < WAD`.
            uint256 feeAssets = totalInterest.mulDiv(fee, WAD);
            // The fee assets is subtracted from the total assets in this calculation to compensate for the fact
            // that total assets is already increased by the total interest (including the fee assets).
            feeShares = _convertToSharesWithTotals(
                feeAssets,
                totalSupply(),
                newTotalAssets - feeAssets,
                Math.Rounding.Floor
            );
        }
    }

    /**
     * @notice Handles the process of depositing assets into the strategy, supplying collateral to the market,
     *         and borrowing assets based on the supplied collateral to achieve the target market utilization via loop.
     * @dev This function performs the following steps:
     *      1. Transfers assets from the caller to the contract.
     *      2. Calculates how much of the deposit should be supplied as collateral and how much should be deposited in the vault.
     *      3. Supplies collateral to the market and borrows additional assets based on the strategy's target loan-to-value (LTV).
     *      4. Repeats the borrowing process while the market utilization is below the target, until the target is met or a max iteration limit is reached.
     *      5. Mints new shares for the receiver based on the deposited assets and updates the vault's total assets.
     *      6. Emits a `Deposit` event after the completion of the deposit process.
     *
     * @param caller The address initiating the deposit.
     * @param receiver The address that will receive the minted shares.
     * @param assets The amount of assets to be deposited.
     * @param shares The amount of shares to be minted to the receiver.
     *
     * @dev Reverts if the market utilization exceeds the target utilization.
     * @dev Emits the `Deposit` event with the caller, receiver, assets, and shares information.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        SafeERC20.safeTransferFrom(
            IERC20(asset()),
            caller,
            address(this),
            assets
        );

        (
            uint256 toSupplyAsCollateral,
            uint256 toSupply
        ) = _calculateAmountsToSupply(assets);

        vault.deposit(toSupply, address(this));

        // calculating how much we should provide as collateral in FLOW
        uint256 toSupplyAsCollateralInFlow = assets - toSupply;
        IWNative(wFlow).withdraw(toSupplyAsCollateralInFlow);
        staking.stakeCerts{value: toSupplyAsCollateralInFlow}();

        markets.supplyCollateral(
            _marketParams,
            toSupplyAsCollateral,
            address(this),
            ""
        );

        (uint256 borrowedAssets, ) = markets.borrow(
            _marketParams,
            toSupply,
            0,
            address(this),
            address(this)
        );

        uint256 currentBorrow = borrowedAssets;

        IWNative(wFlow).withdraw(currentBorrow);
        staking.stakeCerts{value: currentBorrow}();

        uint256 newCollateral = ICertificateToken(ankrFlow).bondsToShares(
            currentBorrow
        );

        markets.supplyCollateral(
            _marketParams,
            newCollateral,
            address(this),
            ""
        );

        Market memory market = markets.market(marketId);
        uint256 utilization = uint256(
            market.totalSupplyAssets > 0
                ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets)
                : 0
        );
        if (utilization > targetUtilization) revert TargetUtilizationReached();

        uint256 lastCollateral = newCollateral;

        uint256 maxIterates = 10;
        uint256 i;
        while (utilization < targetUtilization) {
            if (i >= maxIterates) break;

            uint256 newAmountToBorrowInFlow = ICertificateToken(ankrFlow)
                .sharesToBonds(lastCollateral.wMulDown(targetStrategyLtv));

            uint256 newUtilization = uint256(
                market.totalSupplyAssets > 0
                    ? (market.totalBorrowAssets + newAmountToBorrowInFlow)
                        .wDivDown(market.totalSupplyAssets)
                    : 0
            );

            if (newUtilization < targetUtilization) {
                (borrowedAssets, ) = markets.borrow(
                    _marketParams,
                    newAmountToBorrowInFlow,
                    0,
                    address(this),
                    address(this)
                );
            } else {
                if (
                    market.totalSupplyAssets.wMulDown(targetUtilization) >
                    market.totalBorrowAssets
                ) {
                    (borrowedAssets, ) = markets.borrow(
                        _marketParams,
                        market.totalSupplyAssets.wMulDown(targetUtilization) -
                            market.totalBorrowAssets,
                        0,
                        address(this),
                        address(this)
                    );
                } else break;
            }

            IWNative(wFlow).withdraw(borrowedAssets);
            staking.stakeCerts{value: borrowedAssets}();

            lastCollateral = ICertificateToken(ankrFlow).bondsToShares(
                borrowedAssets
            );

            markets.supplyCollateral(
                _marketParams,
                lastCollateral,
                address(this),
                ""
            );

            market = markets.market(marketId);
            utilization = uint256(
                market.totalSupplyAssets > 0
                    ? market.totalBorrowAssets.wDivDown(
                        market.totalSupplyAssets
                    )
                    : 0
            );
            unchecked {
                ++i;
            }
        }

        _mint(receiver, shares);

        // `lastTotalAssets + assets` may be a little off from `totalAssets()`.
        _updateLastTotalAssets(lastTotalAssets + assets);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Returns the maximum amount of assets that the vault can supply on strategy.
    function _maxDeposit() internal view returns (uint256 totalSuppliable) {
        Market memory market = markets.market(marketId);

        uint256 utilization = uint256(
            market.totalSupplyAssets > 0
                ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets)
                : 0
        );
        if (utilization > targetUtilization) return 0;

        // Since totalSuppliable in our case should be equal to
        // targetUtilization = (totalBorrowAssets + suppliedAssetsAfterSplit) / (totalSupplyAssets + suppliedAssetsAfterSplit)
        // but suppliedAssetsAfterSplit should be less than suppliableToMorphoVault = vault.maxDeposit()
        // hence
        // suppliedAssetsAfterSplit = min(suppliableToMorphoVault, (targetUtilization * totalSupplyAssets - totalBorrowAssets) / (WAD - targetUtilization))
        // now we have to calculate amount of assets that can be deposited in this strategy, before split into collateral and supply
        // to calculate it, we can use flow of the _calculateAmountsToSupply function but reverse it
        // totalSuppliable = (suppliableAssetsAfterSplit(in ankrFlow) / targetStrategyLtv + 1).convertToWFlow() * (100 + targetStrategyLtv) / 100

        uint256 suppliableAssetsAfterSplit = Math.min(
            vault.maxDeposit(address(this)),
            (market.totalSupplyAssets.wMulDown(targetUtilization) -
                market.totalBorrowAssets).wDivDown(WAD - targetUtilization)
        );

        totalSuppliable = ICertificateToken(ankrFlow)
            .sharesToBonds(
                ICertificateToken(ankrFlow)
                    .bondsToShares(suppliableAssetsAfterSplit)
                    .wDivDown(targetStrategyLtv) + 1
            )
            .wMulDown(100 * WAD + targetStrategyLtv.wMulDown(100 * WAD))
            .wDivDown(100 * WAD);
    }

    /**
     * @notice Executes the withdrawal process, including burning shares, repaying loans,
     *         and redeeming collateral, while ensuring proper allocation of withdrawn assets.
     * @dev This function performs the following steps:
     *      1. Validates and spends allowance if the caller is not the asset owner.
     *      2. Burns the specified amount of shares from the owner's balance.
     *      3. Retrieves market parameters and calculates the withdrawal percentage based on `assets`.
     *      4. Accrues market interest to ensure accurate calculations.
     *      5. Computes the collateral and debt repayment amounts proportionate to the withdrawal percentage.
     *      6. Initiates a flash loan to cover the repayment and withdraws collateral from the market.
     *      7. Redeems the corresponding shares from the vault and transfers the withdrawn assets to the receiver.
     *      8. Emits the `Withdraw` event to log the withdrawal details.
     *
     * @param caller The address initiating the withdrawal.
     * @param receiver The address receiving the withdrawn assets.
     * @param owner The address owning the shares to be burned.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares to burn for the withdrawal.
     * @param path The encoded swap path for processing repayment or redemptions.
     *
     * @dev Reverts if the allowance is insufficient (when the caller is not the owner).
     * @dev Emits a `Withdraw` event upon successful withdrawal.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares,
        bytes memory path
    ) internal nonReentrant {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        {
            address tokenIn = address(bytes20(path.slice(0, 20)));
            address tokenOut = address(
                bytes20(path.slice(path.length - 20, path.length))
            );
            if (tokenIn != wFlow || tokenOut != ankrFlow) revert InvalidPath();
        }

        _burn(owner, shares);

        uint256 percentage = _calculatePercentage(assets);

        Position memory position = markets.position(marketId, address(this));
        uint256 collateralToWithdraw = position.collateral.wMulDown(percentage);
        uint256 sharesToRepay = position.borrowShares.wMulDown(percentage);

        uint256 totalBorrowSharesForMultiplier = markets
            .totalBorrowSharesForMultiplier(marketId, position.lastMultiplier);
        uint256 totalBorrowAssetsForMultiplier = markets
            .totalBorrowAssetsForMultiplier(marketId, position.lastMultiplier);

        uint256 assetsToRepay = sharesToRepay.toAssetsUp(
            totalBorrowAssetsForMultiplier,
            totalBorrowSharesForMultiplier
        );

        markets.flashLoan(
            wFlow,
            assetsToRepay,
            abi.encode(
                sharesToRepay,
                collateralToWithdraw,
                assets,
                receiver,
                path
            )
        );

        uint256 sharesToWithdraw = vault.balanceOf(address(this)).wMulDown(
            percentage
        );

        vault.redeem(sharesToWithdraw, receiver, address(this));

        uint256 nativeToWithdraw = IERC20(wFlow)
            .balanceOf(address(this))
            .wMulDown(percentage);
        SafeERC20.safeTransfer(IERC20(wFlow), receiver, nativeToWithdraw);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @notice Calculates the withdrawal percentage based on the specified assets.
     * @dev The withdrawal percentage is calculated by dividing the assets by the total assets.
     * @param assets The amount of assets to withdraw.
     * @return percentage The withdrawal percentage (scaled by 1e18).
     */
    function _calculatePercentage(
        uint256 assets
    ) internal view returns (uint256 percentage) {
        percentage = assets.wDivDown(totalAssets());

        // To prevent rounding errors, round it up to 100%.
        if (percentage > 999999999999990000) {
            percentage = WAD;
        }
    }

    function _calculateAmountsToSupply(
        uint256 assets
    ) internal view returns (uint256 toSupplyAsCollateral, uint256 toSupply) {
        // calculating amount of deposit in ankrFlow
        uint256 depositAmountInAnkrFlow = ICertificateToken(ankrFlow)
            .bondsToShares(assets);
        // calculating how much we should provide as collateral in ankrFlow
        toSupplyAsCollateral =
            depositAmountInAnkrFlow
                .wMulDown(100 * WAD)
                .wDivDown(100 * WAD + targetStrategyLtv.wMulDown(100 * WAD))
                .wMulDown(100 * WAD)
                .wDivDown(100 * WAD) -
            1;
        // calcaulating how much should be provided as supply to the vault in FLOW
        toSupply = ICertificateToken(ankrFlow).sharesToBonds(
            toSupplyAsCollateral.wMulDown(targetStrategyLtv)
        );
    }
}
