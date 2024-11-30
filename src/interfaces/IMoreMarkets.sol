// SPDX-License-Identifier: GNU General Public License v3.0 (GNU GPLv3)
pragma solidity >=0.5.0;

import {Id, Authorization, Signature} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

struct MarketParams {
    bool isPremiumMarket;
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
    address creditAttestationService;
    uint96 irxMaxLltv;
    uint256[] categoryLltv;
}

struct Position {
    uint128 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
    uint64 lastMultiplier;
}

struct CategoryInfo {
    uint112 multiplier;
    uint16 numberOfSteps;
    uint128 lltv;
}

/// @dev Warning: `totalSupplyAssets` does not contain the accrued interest since the last interest accrual.
/// @dev Warning: `totalBorrowAssets` does not contain the accrued interest since the last interest accrual.
/// @dev Warning: `totalSupplyShares` does not contain the additional shares accrued by `feeRecipient` since the last
/// interest accrual.
struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
    uint256 premiumFee;
}

/// @dev This interface is used for factorizing IMoreMarketsStaticTyping and IMoreMarkets.
/// @dev Consider using the IMoreMarkets interface instead of this one.
interface IMoreMarketsBase {
    /// @notice The EIP-712 domain separator.
    /// @dev Warning: Every EIP-712 signed message based on this domain separator can be reused on another chain sharing
    /// the same chain id because the domain separator would be the same.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice The owner of the contract.
    /// @dev It has the power to change the owner.
    /// @dev It has the power to set fees on markets and set the fee recipient.
    /// @dev It has the power to enable but not disable IRMs and LLTVs.
    function owner() external view returns (address);

    /// @notice The fee recipient of all markets.
    /// @dev The recipient receives the fees of a given market through a supply position on that market.
    function feeRecipient() external view returns (address);

    /// @notice Whether the `irm` is enabled.
    function isIrmEnabled(address irm) external view returns (bool);

    /// @notice Whether the `lltv` is enabled.
    function isLltvEnabled(uint256 lltv) external view returns (bool);

    /// @notice Whether `authorized` is authorized to modify `authorizer`'s position on all markets.
    /// @dev Anyone is authorized to modify their own positions, regardless of this variable.
    function isAuthorized(
        address authorizer,
        address authorized
    ) external view returns (bool);

    /// @notice The `authorizer`'s current nonce. Used to prevent replay attacks with EIP-712 signatures.
    function nonce(address authorizer) external view returns (uint256);

    /// @notice Total amount of assets borrowed on a given market for particular multiplier.
    function totalBorrowAssetsForMultiplier(
        Id marketId,
        uint64 multiplier
    ) external view returns (uint256);

    /// @notice Total amount of shares borrowed on a given market for particular multiplier.
    function totalBorrowSharesForMultiplier(
        Id marketId,
        uint64 multiplier
    ) external view returns (uint256);

    /// @notice Upper limit for irxMaxLltv to set.
    function irxMaxAvailable() external view returns (uint256);

    /// @notice Upper limit for categoryLltv to set.
    function maxLltvForCategory() external view returns (uint256);

    /// @notice Array of ids of created markets.
    function arrayOfMarkets() external view returns (Id[] memory);

    /// @notice Initializes the contract.
    /// @param newOwner The new owner of the contract.
    function initialize(address newOwner) external;

    /// @notice Sets `newOwner` as `owner` of the contract.
    /// @dev Warning: No two-step transfer ownership.
    /// @dev Warning: The owner can be set to the zero address.
    function setOwner(address newOwner) external;

    /// @notice Enables `irm` as a possible IRM for market creation.
    /// @dev Warning: It is not possible to disable an IRM.
    function enableIrm(address irm) external;

    /// @notice Enables `lltv` as a possible LLTV for market creation.
    /// @dev Warning: It is not possible to disable a LLTV.
    function enableLltv(uint256 lltv) external;

    /// @notice Sets `irxMaxAvailable` as a upper limit for market creation.
    function setIrxMax(uint256 irxMaxAvailable) external;

    /// @notice Sets `maxLltvForCategory` as a upper limit of any `categoryLltv` for market creation.
    function setMaxLltvForCategory(uint256 _maxLltvForCategory) external;

    /// @notice Sets the `newFee` for the given market `marketParams`.
    /// @param newFee The new fee, scaled by WAD.
    /// @dev Warning: The recipient can be the zero address.
    function setFee(MarketParams memory marketParams, uint256 newFee) external;

    /// @notice Sets the `newPremiumFee` for the given market `marketParams`.
    /// @param marketParams Parameters of the market.
    /// @param newPremiumFee The new fee, scaled by WAD.
    /// @dev Warning: The recipient can be the zero address.
    function setPremiumFee(
        MarketParams memory marketParams,
        uint256 newPremiumFee
    ) external;

    /// @notice Sets `newFeeRecipient` as `feeRecipient` of the fee.
    /// @dev Warning: If the fee recipient is set to the zero address, fees will accrue there and will be lost.
    /// @dev Modifying the fee recipient will allow the new recipient to claim any pending fees not yet accrued. To
    /// ensure that the current recipient receives all due fees, accrue interest manually prior to making any changes.
    function setFeeRecipient(address newFeeRecipient) external;

    /// @notice Creates the market `marketParams`.
    /// @dev Here is the list of assumptions on the market's dependencies (tokens, IRM and oracle) that guarantees
    /// MoreMarkets behaves as expected:
    /// - The token should be ERC-20 compliant, except that it can omit return values on `transfer` and `transferFrom`.
    /// - The token balance of MoreMarkets should only decrease on `transfer` and `transferFrom`. In particular, tokens with
    /// burn functions are not supported.
    /// - The token should not re-enter MoreMarkets on `transfer` nor `transferFrom`.
    /// - The token balance of the sender (resp. receiver) should decrease (resp. increase) by exactly the given amount
    /// on `transfer` and `transferFrom`. In particular, tokens with fees on transfer are not supported.
    /// - The IRM should not re-enter MoreMarkets.
    /// - The oracle should return a price with the correct scaling.
    /// - The credit attestation service should be ICreditAttestationService compliant. It should be able to return
    /// scores of the users by getScores(address) returns(uint256) call and this score should be between 1e18 and 1000 * 1e18.
    /// Any score higher or equal than 1000 * 1e18 will be considered as 1000 * 1e18.
    /// - The irxMaxLltv should be between irxMaxAvailable and 1e18.
    /// - The ltvMaxLltv should be between maxLltvForCategory and default lltv.
    /// @dev Here is a list of properties on the market's dependencies that could break MoreMarkets's liveness properties
    /// (funds could get stuck):
    /// - The token can revert on `transfer` and `transferFrom` for a reason other than an approval or balance issue.
    /// - A very high amount of assets (~1e35) supplied or borrowed can make the computation of `toSharesUp` and
    /// `toSharesDown` overflow.
    /// - The IRM can revert on `borrowRate`.
    /// - A very high borrow rate returned by the IRM can make the computation of `interest` in `_accrueInterest`
    /// overflow.
    /// - The oracle can revert on `price`. Note that this can be used to prevent `borrow`, `withdrawCollateral` and
    /// `liquidate` from being used under certain market conditions.
    /// - A very high price returned by the oracle can make the computation of `maxBorrow` in `_isHealthy` overflow, or
    /// the computation of `assetsRepaid` in `liquidate` overflow.
    /// @dev The borrow share price of a market with less than 1e4 assets borrowed can be decreased by manipulations, to
    /// the point where `totalBorrowShares` is very large and borrowing overflows.
    function createMarket(MarketParams memory marketParams) external;

    /// @notice Supplies `assets` or `shares` on behalf of `onBehalf`, optionally calling back the caller's
    /// `onMorphoSupply` function with the given `data`.
    /// @dev Either `assets` or `shares` should be zero. Most use cases should rely on `assets` as an input so the
    /// caller is guaranteed to have `assets` tokens pulled from their balance, but the possibility to mint a specific
    /// amount of shares is given for full compatibility and precision.
    /// @dev Supplying a large amount can revert for overflow.
    /// @dev Supplying an amount of shares may lead to supply more or fewer assets than expected due to slippage.
    /// Consider using the `assets` parameter to avoid this.
    /// @param marketParams The market to supply assets to.
    /// @param assets The amount of assets to supply.
    /// @param shares The amount of shares to mint.
    /// @param onBehalf The address that will own the increased supply position.
    /// @param data Arbitrary data to pass to the `onMorphoSupply` callback. Pass empty data if not needed.
    /// @return assetsSupplied The amount of assets supplied.
    /// @return sharesSupplied The amount of shares minted.
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    /// @notice Withdraws `assets` or `shares` on behalf of `onBehalf` and sends the assets to `receiver`.
    /// @dev Either `assets` or `shares` should be zero. To withdraw max, pass the `shares`'s balance of `onBehalf`.
    /// @dev `msg.sender` must be authorized to manage `onBehalf`'s positions.
    /// @dev Withdrawing an amount corresponding to more shares than supplied will revert for underflow.
    /// @dev It is advised to use the `shares` input when withdrawing the full position to avoid reverts due to
    /// conversion roundings between shares and assets.
    /// @param marketParams The market to withdraw assets from.
    /// @param assets The amount of assets to withdraw.
    /// @param shares The amount of shares to burn.
    /// @param onBehalf The address of the owner of the supply position.
    /// @param receiver The address that will receive the withdrawn assets.
    /// @return assetsWithdrawn The amount of assets withdrawn.
    /// @return sharesWithdrawn The amount of shares burned.
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    /// @notice Borrows `assets` or `shares` on behalf of `onBehalf` and sends the assets to `receiver`.
    /// @dev Either `assets` or `shares` should be zero. Most use cases should rely on `assets` as an input so the
    /// caller is guaranteed to borrow `assets` of tokens, but the possibility to mint a specific amount of shares is
    /// given for full compatibility and precision.
    /// @dev `msg.sender` must be authorized to manage `onBehalf`'s positions.
    /// @dev Borrowing a large amount can revert for overflow.
    /// @dev Borrowing an amount of shares may lead to borrow fewer assets than expected due to slippage.
    /// Consider using the `assets` parameter to avoid this.
    /// @param marketParams The market to borrow assets from.
    /// @param assets The amount of assets to borrow.
    /// @param shares The amount of shares to mint.
    /// @param onBehalf The address that will own the increased borrow position.
    /// @param receiver The address that will receive the borrowed assets.
    /// @return assetsBorrowed The amount of assets borrowed.
    /// @return sharesBorrowed The amount of shares minted.
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    /// @notice Repays `assets` or `shares` on behalf of `onBehalf`, optionally calling back the caller's
    /// `onMorphoReplay` function with the given `data`.
    /// @dev Either `assets` or `shares` should be zero. To repay max, pass the `shares`'s balance of `onBehalf`.
    /// @dev Repaying an amount corresponding to more shares than borrowed will revert for underflow.
    /// @dev It is advised to use the `shares` input when repaying the full position to avoid reverts due to conversion
    /// roundings between shares and assets.
    /// @dev An attacker can front-run a repay with a small repay making the transaction revert for underflow.
    /// @param marketParams The market to repay assets to.
    /// @param assets The amount of assets to repay.
    /// @param shares The amount of shares to burn.
    /// @param onBehalf The address of the owner of the debt position.
    /// @param data Arbitrary data to pass to the `onMorphoRepay` callback. Pass empty data if not needed.
    /// @return assetsRepaid The amount of assets repaid.
    /// @return sharesRepaid The amount of shares burned.
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @notice Supplies `assets` of collateral on behalf of `onBehalf`, optionally calling back the caller's
    /// `onMorphoSupplyCollateral` function with the given `data`.
    /// @dev Interest are not accrued since it's not required and it saves gas.
    /// @dev Supplying a large amount can revert for overflow.
    /// @param marketParams The market to supply collateral to.
    /// @param assets The amount of collateral to supply.
    /// @param onBehalf The address that will own the increased collateral position.
    /// @param data Arbitrary data to pass to the `onMorphoSupplyCollateral` callback. Pass empty data if not needed.
    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external;

    /// @notice Withdraws `assets` of collateral on behalf of `onBehalf` and sends the assets to `receiver`.
    /// @dev `msg.sender` must be authorized to manage `onBehalf`'s positions.
    /// @dev Withdrawing an amount corresponding to more collateral than supplied will revert for underflow.
    /// @param marketParams The market to withdraw collateral from.
    /// @param assets The amount of collateral to withdraw.
    /// @param onBehalf The address of the owner of the collateral position.
    /// @param receiver The address that will receive the collateral assets.
    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    /// @notice Function that updates the premium borrower's current interest rate multiplier if conditions are met.
    /// Since because of fluctuating of the market LTV of the users can change, it has to be checked if the conditions are met
    /// and update the multiplier of the borrower.
    /// @param marketParams The market at which position will be updated.
    /// @param borrower The address of the borrower of which position will be updated.
    function updateBorrower(
        MarketParams memory marketParams,
        address borrower
    ) external;

    /// @notice Liquidates the given `repaidShares` of debt asset or seize the given `seizedAssets` of collateral on the
    /// given market `marketParams` of the given `borrower`'s position, optionally calling back the caller's
    /// `onMorphoLiquidate` function with the given `data`.
    /// @dev Either `seizedAssets` or `repaidShares` should be zero.
    /// @dev Seizing more than the collateral balance will underflow and revert without any error message.
    /// @dev Repaying more than the borrow balance will underflow and revert without any error message.
    /// @dev An attacker can front-run a liquidation with a small repay making the transaction revert for underflow.
    /// @param marketParams The market of the position.
    /// @param borrower The owner of the position.
    /// @param seizedAssets The amount of collateral to seize.
    /// @param repaidShares The amount of shares to repay.
    /// @param data Arbitrary data to pass to the `onMorphoLiquidate` callback. Pass empty data if not needed.
    /// @return The amount of assets seized.
    /// @return The amount of assets repaid.
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256);

    /// @notice Executes a flash loan.
    /// @dev Flash loans have access to the whole balance of the contract (the liquidity and deposited collateral of all
    /// markets combined, plus donations).
    /// @dev Warning: Not ERC-3156 compliant but compatibility is easily reached:
    /// - `flashFee` is zero.
    /// - `maxFlashLoan` is the token's balance of this contract.
    /// - The receiver of `assets` is the caller.
    /// @param token The token to flash loan.
    /// @param assets The amount of assets to flash loan.
    /// @param data Arbitrary data to pass to the `onMorphoFlashLoan` callback.
    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external;

    /// @notice Sets the authorization for `authorized` to manage `msg.sender`'s positions.
    /// @param authorized The authorized address.
    /// @param newIsAuthorized The new authorization status.
    function setAuthorization(
        address authorized,
        bool newIsAuthorized
    ) external;

    /// @notice Sets the authorization for `authorization.authorized` to manage `authorization.authorizer`'s positions.
    /// @dev Warning: Reverts if the signature has already been submitted.
    /// @dev The signature is malleable, but it has no impact on the security here.
    /// @dev The nonce is passed as argument to be able to revert with a different error message.
    /// @param authorization The `Authorization` struct.
    /// @param signature The signature.
    function setAuthorizationWithSig(
        Authorization calldata authorization,
        Signature calldata signature
    ) external;

    /// @notice Accrues interest for the given market `marketParams`.
    function accrueInterest(MarketParams memory marketParams) external;

    /// @notice Returns the data stored on the different `slots`.
    function extSloads(
        bytes32[] memory slots
    ) external view returns (bytes32[] memory);
}

/// @dev This interface is inherited by MoreMarkets so that function signatures are checked by the compiler.
/// @dev Consider using the IMoreMarkets interface instead of this one.
interface IMoreMarketsStaticTyping is IMoreMarketsBase {
    function position(
        Id id,
        address user
    )
        external
        view
        returns (
            uint128 supplyShares,
            uint128 borrowShares,
            uint128 collateral,
            uint64 lastMultiplier
        );

    /// @notice The state of the market corresponding to `id`.
    /// @dev Warning: `totalSupplyAssets` does not contain the accrued interest since the last interest accrual.
    /// @dev Warning: `totalBorrowAssets` does not contain the accrued interest since the last interest accrual.
    /// @dev Warning: `totalSupplyShares` does not contain the accrued shares by `feeRecipient` since the last interest
    /// accrual.
    function market(
        Id id
    )
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee,
            uint256 premiumFee
        );

    /// @notice The market params corresponding to `id`.
    /// @dev This mapping is not used in MoreMarkets. It is there to enable reducing the cost associated to calldata on layer
    /// 2s by creating a wrapper contract with functions that take `id` as input instead of `marketParams`.
    function idToMarketParams(
        Id id
    )
        external
        view
        returns (
            bool isPremiumMarket,
            address loanToken,
            address collateralToken,
            address oracle,
            address irm,
            uint256 lltv,
            address creditAttestationService,
            uint96 irxMaxLltv,
            uint256[] memory categoryLltv
        );
}

interface IMoreMarkets is IMoreMarketsBase {
    function position(
        Id id,
        address user
    ) external view returns (Position memory);

    /// @notice The state of the market corresponding to `id`.
    /// @dev Warning: `totalSupplyAssets` does not contain the accrued interest since the last interest accrual.
    /// @dev Warning: `totalBorrowAssets` does not contain the accrued interest since the last interest accrual.
    /// @dev Warning: `totalSupplyShares` does not contain the accrued shares by `feeRecipient` since the last interest
    /// accrual.
    function market(Id id) external view returns (Market memory);

    /// @notice The market params corresponding to `id`.
    /// @dev This mapping is not used in MoreMarkets. It is there to enable reducing the cost associated to calldata on layer
    /// 2s by creating a wrapper contract with functions that take `id` as input instead of `marketParams`.
    function idToMarketParams(
        Id id
    )
        external
        view
        returns (
            bool isPremiumMarket,
            address loanToken,
            address collateralToken,
            address oracle,
            address irm,
            uint256 lltv,
            address creditAttestationService,
            uint96 irxMaxLltv,
            uint256[] memory categoryLltv
        );

    /// @notice Updates the borrower position state in the market. It should change multiplier for
    /// premium borrowers if their LLTV reached any treshold.
    /// @param marketParams The market parameters.
    /// @param borrower The borrower address.
    function updateBorrower(
        MarketParams memory marketParams,
        address borrower
    ) external;

    /// @notice Returns the available multipliers for the given market `id`.
    /// @param id The market id.
    /// @return The array of available multipliers.
    function availableMultipliers(
        Id id
    ) external view returns (uint256[] memory);
}
