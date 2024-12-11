// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IMoreMarkets, Market, Id} from "./IMoreMarkets.sol";
import {ILiquidTokenStakingPool} from "./ILiquidTokenStakingPool.sol";
import {IMoreVaults} from "./IMoreVaults.sol";
import {ITradoSwap} from "./ITradoSwap.sol";

import {IERC4626, IERC20Metadata} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

/**
 * @title LoopStrategy Interface
 * @notice Interface for interacting with the LoopStrategy contract
 */
interface ILoopStrategy is IERC4626 {
    /// @notice Emitted when interest is accrued.
    /// @param newTotalAssets The assets of the vault after accruing the interest but before the interaction.
    /// @param feeShares The shares minted to the fee recipient.
    event AccrueInterest(
        uint256 indexed newTotalAssets,
        uint256 indexed feeShares
    );

    /// @notice Emitted when `fee` is updated.
    /// @param caller The address that updated the fee.
    /// @param newFee The new fee value.
    event SetFee(address indexed caller, uint256 indexed newFee);

    /// @notice Emitted when a new fee recipient is set.
    /// @param newFeeRecipient The address of the new fee recipient.
    event SetFeeRecipient(address indexed newFeeRecipient);

    /// @notice Emitted when a new maximum loss percentage for swaps is set.
    /// @param newMaxLossPercent The new maximum loss percentage.
    event SetSwapMaxLossPercent(uint256 indexed newMaxLossPercent);

    /// @notice Emitted when a new target utilization is set.
    /// @param newTargetUtilization The new target utilization value.
    event SetTargetUtilization(uint256 indexed newTargetUtilization);

    /**
     * @notice Initializes the LoopStrategy contract.
     * @param owner The address of the owner.
     * @param moreMarkets Address of the MoreMarkets contract.
     * @param _vault Address of the vault.
     * @param _staking Address of the staking pool.
     * @param _asset Address of the underlying asset.
     * @param _ankrFlow Address of the certificate token for ankrFlow.
     * @param _router Address of the TradoSwap router.
     * @param _marketId Market identifier for MoreMarkets.
     * @param _targetUtilization Target utilization percentage (scaled by 1e18).
     * @param _targetStrategyLtv Target loan-to-value ratio for the strategy.
     * @param _swapMaxLossPercent Maximum loss percentage allowed during swaps.
     * @param _protocolFeeManager Address of the protocol fee manager.
     * @param _name Name of the ERC20 token.
     * @param _symbol Symbol of the ERC20 token.
     */
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
    ) external;

    /**
     * @notice Sets a new performance fee.
     * @param newFee The new fee value (scaled by 1e18).
     */
    function setFee(uint256 newFee) external;

    /**
     * @notice Sets a new fee recipient.
     * @param newFeeRecipient The address of the new fee recipient.
     */
    function setFeeRecipient(address newFeeRecipient) external;

    /**
     * @notice Sets a new maximum loss percentage for swaps.
     * @param _swapMaxLossPercent The new maximum loss percentage (scaled by 1e18).
     */
    function setSwapMaxLossPercent(uint256 _swapMaxLossPercent) external;

    /**
     * @notice Sets a new target utilization percentage.
     * @param _newTargetUtilization The new target utilization percentage (scaled by 1e18).
     */
    function setTargetUtilization(uint256 _newTargetUtilization) external;

    /**
     * @notice Redeems shares for underlying assets.
     * @param shares The amount of shares to redeem.
     * @param receiver The address receiving the withdrawn assets.
     * @param owner The address owning the shares.
     * @param path The path to use for swaps.
     * @return assets The amount of assets withdrawn.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        bytes memory path
    ) external returns (uint256 assets);

    /**
     * @notice Withdraws assets by burning shares.
     * @param assets The amount of assets to withdraw.
     * @param receiver The address receiving the withdrawn assets.
     * @param owner The address owning the shares.
     * @param path The path to use for swaps.
     * @return shares The amount of shares burned.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        bytes memory path
    ) external returns (uint256 shares);

    /**
     * @notice Calculates expected repayment and received amounts during withdrawal.
     * @param assets The amount of assets to withdraw.
     * @return amountToRepay The debt amount to repay.
     * @return wFlowAmount The amount of wFlow to receive.
     * @return ankrFlowAmount The amount of ankrFlow to receive.
     */
    function expectedAmountsToWithdraw(
        uint256 assets
    )
        external
        view
        returns (
            uint256 amountToRepay,
            uint256 wFlowAmount,
            uint256 ankrFlowAmount
        );

    /**
     * @notice Returns the address of the MoreMarkets contract.
     * @return Address of the MoreMarkets contract.
     */
    function markets() external view returns (IMoreMarkets);

    /**
     * @notice Returns the address of the Liquid Token Staking Pool contract.
     * @return Address of the staking pool contract.
     */
    function staking() external view returns (ILiquidTokenStakingPool);

    /**
     * @notice Returns the address of the MoreVaults contract.
     * @return Address of the vault contract.
     */
    function vault() external view returns (IMoreVaults);

    /**
     * @notice Returns the address of the TradoSwap router.
     * @return Address of the router.
     */
    function router() external view returns (ITradoSwap);

    /**
     * @notice Returns the identifier of the associated market.
     * @return Market ID.
     */
    function marketId() external view returns (Id);

    /**
     * @notice Returns the address of the ankrFlow token.
     * @return Address of the ankrFlow token.
     */
    function ankrFlow() external view returns (address);

    /**
     * @notice Returns the address of the wrapped FLOW token.
     * @return Address of the wFlow token.
     */
    function wFlow() external view returns (address);

    /**
     * @notice Returns the target utilization percentage for the strategy.
     * @return Target utilization (scaled by 1e18).
     */
    function targetUtilization() external view returns (uint256);

    /**
     * @notice Returns the target loan-to-value ratio for the strategy.
     * @return Target strategy LTV (scaled by 1e18).
     */
    function targetStrategyLtv() external view returns (uint256);

    /**
     * @notice Returns the maximum allowable loss percentage during swaps.
     * @return Maximum loss percentage (scaled by 1e18).
     */
    function swapMaxLossPercent() external view returns (uint256);

    /**
     * @notice Returns the default path for swaps.
     * @return Default swap path as bytes.
     */
    function defaultPath() external view returns (bytes memory);

    /**
     * @notice Returns the address of the fee recipient.
     * @return Address of the fee recipient.
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Returns the current performance fee.
     * @return Performance fee (scaled by 1e18).
     */
    function fee() external view returns (uint96);

    /**
     * @notice Returns the address of the protocol fee manager.
     * @return Address of the protocol fee manager.
     */
    function protocolFeeManager() external view returns (address);

    /**
     * @notice Returns the last recorded total assets of the vault.
     * @return Last total assets value.
     */
    function lastTotalAssets() external view returns (uint256);
}
