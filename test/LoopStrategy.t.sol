// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {Test, console} from "forge-std/Test.sol";
import {Id, IMoreMarkets, Market, Position, MarketParams} from "../src/interfaces/IMoreMarkets.sol";
import {IMoreVaults} from "../src/interfaces/IMoreVaults.sol";

import {MathLib, WAD} from "../src/libraries/MathLib.sol";
import {UtilsLib} from "../src/libraries/UtilsLib.sol";
import {SharesMathLib} from "../src/libraries/SharesMathLib.sol";

// import {MarketParamsLib} from "../contracts/MoreMarkets.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {LoopStrategy, ILoopStrategy} from "../src/LoopStrategy.sol";
import {ProtocolFeeManager} from "../src/ProtocolFeeManager.sol";
import {ICertificateToken} from "../src/interfaces/ICertificateToken.sol";
import {ILiquidTokenStakingPool} from "../src/interfaces/ILiquidTokenStakingPool.sol";
import {IWNative} from "../src/interfaces/IWNative.sol";

interface IQuoter {
    function swapDesire(
        uint128 desire,
        bytes memory path
    ) external returns (uint256 swapCost, int24[] memory pointAfterList);
}

contract LoopStrategyTest is Test {
    // using MarketParamsLib for MarketParams;
    using Math for uint256;
    using MathLib for uint128;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    event SetSwapMaxLossPercent(uint256 _swapMaxLossPercent);
    event SetTargetUtilization(uint256 indexed newTargetUtilization);
    event SetFee(address indexed caller, uint256 newFee);
    event SetFeeRecipient(address indexed newFeeRecipient);

    IQuoter public quoter =
        IQuoter(address(0x33531bDBFE34fa6Fd5963D0423f7699775AacaaF));
    ICertificateToken public ankrFlow =
        ICertificateToken(address(0x1b97100eA1D7126C4d60027e231EA4CB25314bdb));
    IWNative public wFlow =
        IWNative(address(0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e));
    ILiquidTokenStakingPool public staking =
        ILiquidTokenStakingPool(
            address(0xFE8189A3016cb6A3668b8ccdAC520CE572D4287a)
        );
    Id public marketId =
        Id.wrap(
            bytes32(
                0x2ae0c40dc06f58ff0243b44116cd48cc4bdab19e2474792fbf1f413600ceab3a
            )
        );
    uint256 targetUtilization = 0.9e18;
    uint256 targetStrategyLtv = 0.85e18;
    uint256 swapMaxLossPercent = 0.015e18;
    uint96 protocolFeePercent = 0.1e18;
    IMoreMarkets public markets =
        IMoreMarkets(0x94A2a9202EFf6422ab80B6338d41c89014E5DD72);
    IMoreVaults public vault =
        IMoreVaults(address(0xe2aaC46C1272EEAa49ec7e7B9e7d34B90aaDB966));
    address router = address(0xC0Ac932CaC7B4D8F7c31792082e2e8F3CFe99c10);

    TransparentUpgradeableProxy public transparentProxy;
    ProxyAdmin public proxyAdmin;
    LoopStrategy public implementation;
    LoopStrategy public strategy;
    ProtocolFeeManager public manager;
    address public owner = address(0x89a76D7a4D006bDB9Efd0923A346fAe9437D434F);

    uint256 sepoliaFork;
    uint256 flowTestnetFork;
    uint256 flowMainnetFork;

    address alice = address(0xABCD);
    address bob = address(0xABCE);
    address protocolFeeRecipient = address(0xABCF);

    uint256 constant MAX_TEST_DEPOSIT = 10000000 ether;
    uint256 constant MIN_TEST_DEPOSIT = 0.1 ether;

    bytes public defaultPath;

    function setUp() public {
        defaultPath = abi.encodePacked(
            address(wFlow),
            uint24(500),
            address(ankrFlow)
        );

        flowTestnetFork = vm.createFork("https://testnet.evm.nodes.onflow.org");
        flowMainnetFork = vm.createFork(
            "https://mainnet.evm.nodes.onflow.org",
            9230765
        );
        vm.selectFork(flowMainnetFork);

        manager = new ProtocolFeeManager();
        manager.initialize(owner);

        implementation = new LoopStrategy();
        transparentProxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(owner),
            ""
        );
        strategy = LoopStrategy(payable(transparentProxy));
        strategy.initialize(
            owner,
            address(markets),
            address(vault),
            address(staking),
            address(wFlow),
            address(ankrFlow),
            address(router),
            marketId,
            targetUtilization,
            targetStrategyLtv,
            swapMaxLossPercent,
            address(manager),
            "LoopStrategy",
            "LS"
        );

        startHoax(owner);
        manager.setProtocolFeeRecipient(protocolFeeRecipient);
        manager.setProtocolFee(address(strategy), protocolFeePercent);

        deal(alice, MAX_TEST_DEPOSIT * 1e5);
        deal(bob, MAX_TEST_DEPOSIT * 1e5);
    }

    function test_withdrawOnFork() public {
        alice = address(0xF56EcB3b2204f12069bf99E94Cf9a01F3DedC1c8);
        startHoax(alice);
        strategy = LoopStrategy(
            payable(address(0xBEe4769E53d1A6BABC4fC2E91F9B730770453bad))
        );

        uint256 amountToWithdraw = strategy.convertToAssets(
            strategy.balanceOf(alice)
        );
        (uint256 amountToRepay, , ) = strategy.expectedAmountsToWithdraw(
            amountToWithdraw
        );

        wFlow.approve(address(strategy), amountToRepay + 1e13);
        strategy.withdraw(amountToWithdraw, alice, alice);
    }

    function test_setSwapMaxLossPercent_shouldSetCorrectlyByAnOwner(
        uint256 _swapMaxLossPercent
    ) public {
        vm.assume(_swapMaxLossPercent != swapMaxLossPercent);

        startHoax(owner);
        assertEq(strategy.swapMaxLossPercent(), swapMaxLossPercent);
        strategy.setSwapMaxLossPercent(_swapMaxLossPercent);
        assertEq(strategy.swapMaxLossPercent(), _swapMaxLossPercent);
    }

    function test_setSwapMaxLossPercent_shouldEmitSetSwapMaxLossPercent(
        uint256 _swapMaxLossPercent
    ) public {
        vm.assume(_swapMaxLossPercent != swapMaxLossPercent);
        startHoax(owner);

        vm.expectEmit(true, true, false, true);
        emit ILoopStrategy.SetSwapMaxLossPercent(_swapMaxLossPercent);
        strategy.setSwapMaxLossPercent(_swapMaxLossPercent);
    }

    function test_setSwapMaxLossPercent_shouldRevertIfCalledNotByAnOwnerNorCurator(
        uint256 _swapMaxLossPercent
    ) public {
        startHoax(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        strategy.setSwapMaxLossPercent(_swapMaxLossPercent);
    }

    function test_setSwapMaxLossPercent_shouldRevertIfSetSameValue() public {
        startHoax(owner);

        vm.expectRevert(LoopStrategy.AlreadySet.selector);
        strategy.setSwapMaxLossPercent(swapMaxLossPercent);
    }

    function test_setTargetUtilization_shouldSetCorrectlyByAnOwner(
        uint256 _newTargetUtilization
    ) public {
        vm.assume(_newTargetUtilization != targetUtilization);
        startHoax(owner);
        assertEq(strategy.targetUtilization(), targetUtilization);
        strategy.setTargetUtilization(_newTargetUtilization);
        assertEq(strategy.targetUtilization(), _newTargetUtilization);
    }

    function test_setTargetUtilization_shouldEmitSetTargetUtilization(
        uint256 _newTargetUtilization
    ) public {
        vm.assume(_newTargetUtilization != targetUtilization);
        startHoax(owner);

        vm.expectEmit(true, true, false, true);
        emit ILoopStrategy.SetTargetUtilization(_newTargetUtilization);
        strategy.setTargetUtilization(_newTargetUtilization);
    }

    function test_setTargetUtilization_shouldRevertIfCalledNotByAnOwnerNorCurator(
        uint256 _newTargetUtilization
    ) public {
        startHoax(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        strategy.setSwapMaxLossPercent(_newTargetUtilization);
    }

    function test_setTargetUtilization_shouldRevertIfSetSameValue() public {
        startHoax(owner);

        vm.expectRevert(LoopStrategy.AlreadySet.selector);
        strategy.setSwapMaxLossPercent(swapMaxLossPercent);
    }

    function test_setFeeRecipient_shouldSetCorrectlyByAnOwner(
        address _newFeeRecipient
    ) public {
        vm.assume(_newFeeRecipient != address(0));
        startHoax(owner);
        assertEq(strategy.feeRecipient(), address(0));
        strategy.setFeeRecipient(_newFeeRecipient);
        assertEq(strategy.feeRecipient(), _newFeeRecipient);
    }

    function test_setFeeRecipient_shouldEmitSetFeeRecipient(
        address _newFeeRecipient
    ) public {
        vm.assume(_newFeeRecipient != address(0));
        startHoax(owner);

        vm.expectEmit(true, true, false, true);
        emit ILoopStrategy.SetFeeRecipient(_newFeeRecipient);
        strategy.setFeeRecipient(_newFeeRecipient);
    }

    function test_setFeeRecipient_shouldRevertIfCalledNotByAnOwnerNorCurator(
        address _newFeeRecipient
    ) public {
        startHoax(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        strategy.setFeeRecipient(_newFeeRecipient);
    }

    function test_setFeeRecipient_shouldRevertIfSetSameValue() public {
        startHoax(owner);

        vm.expectRevert(LoopStrategy.AlreadySet.selector);
        strategy.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_shouldRevertIfSetZeroAddressWhileFeeNotZero()
        public
    {
        startHoax(owner);

        strategy.setFeeRecipient(alice);
        strategy.setFee(0.1e18);

        vm.expectRevert(LoopStrategy.ZeroFeeRecipient.selector);
        strategy.setFeeRecipient(address(0));
    }

    function test_setFee_shouldSetCorrectlyByAnOwner(uint96 _newFee) public {
        vm.assume(_newFee <= 0.5e18);
        vm.assume(_newFee > 0);
        startHoax(owner);
        strategy.setFeeRecipient(alice);
        assertEq(strategy.fee(), 0);
        strategy.setFee(_newFee);
        assertEq(strategy.fee(), _newFee);
    }

    function test_setFee_shouldEmitSetFee(uint96 _newFee) public {
        vm.assume(_newFee <= 0.5e18);
        vm.assume(_newFee > 0);
        startHoax(owner);
        strategy.setFeeRecipient(alice);

        vm.expectEmit(true, true, false, true);
        emit ILoopStrategy.SetFee(owner, _newFee);
        strategy.setFee(_newFee);
    }

    function test_setFee_shouldRevertIfCalledNotByAnOwnerNorCurator(
        uint96 _newFee
    ) public {
        startHoax(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        strategy.setFee(_newFee);
    }

    function test_setFee_shouldRevertIfSetSameValue() public {
        startHoax(owner);
        strategy.setFeeRecipient(alice);

        vm.expectRevert(LoopStrategy.AlreadySet.selector);
        strategy.setFee(0);
    }

    function test_setFee_shouldRevertIfAboveMaxFee() public {
        startHoax(owner);
        strategy.setFeeRecipient(alice);

        vm.expectRevert(LoopStrategy.MaxFeeExceeded.selector);
        strategy.setFee(0.5e18 + 1);
    }

    function test_setFee_shouldRevertIfFeeRecipientZeroAddress() public {
        startHoax(owner);

        vm.expectRevert(LoopStrategy.ZeroFeeRecipient.selector);
        strategy.setFee(0.1e18);
    }

    function test_deposit_oneUserSharesMintedCorrectly(
        uint256 amountToDeposit
    ) public {
        vm.assume(amountToDeposit > MIN_TEST_DEPOSIT);
        vm.assume(amountToDeposit < MAX_TEST_DEPOSIT);
        startHoax(alice);
        IWNative(wFlow).deposit{value: amountToDeposit * 1e4}();
        assertEq(wFlow.balanceOf(alice), amountToDeposit * 1e4);

        wFlow.approve(address(strategy), amountToDeposit);
        strategy.deposit(amountToDeposit, alice);

        assertEq(strategy.balanceOf(alice), amountToDeposit);
        assertApproxEqAbs(strategy.totalAssets(), amountToDeposit, 1e3);
        assertEq(
            strategy.convertToAssets(strategy.balanceOf(alice)),
            strategy.totalAssets()
        );

        Market memory market = markets.market(marketId);
        uint256 utilization = uint256(
            market.totalSupplyAssets > 0
                ? (market.totalBorrowAssets).wDivDown(market.totalSupplyAssets)
                : 0
        );
        assertLe(utilization, targetUtilization);

        Position memory position = markets.position(
            marketId,
            address(strategy)
        );

        assertEq(position.supplyShares, 0);
        assertGt(position.borrowShares, 0);
        assertGt(position.collateral, 0);
        assertGt(vault.balanceOf(address(strategy)), 0);
    }

    function test_deposit_oneUserUtilizationShouldBeLessThanTarget(
        uint256 amountToDeposit
    ) public {
        vm.assume(amountToDeposit > MIN_TEST_DEPOSIT);
        vm.assume(amountToDeposit < MAX_TEST_DEPOSIT);
        startHoax(alice);
        IWNative(wFlow).deposit{value: amountToDeposit * 1e4}();
        assertEq(wFlow.balanceOf(alice), amountToDeposit * 1e4);

        wFlow.approve(address(strategy), amountToDeposit);
        strategy.deposit(amountToDeposit, alice);

        Market memory market = markets.market(marketId);
        uint256 utilization = uint256(
            market.totalSupplyAssets > 0
                ? (market.totalBorrowAssets).wDivDown(market.totalSupplyAssets)
                : 0
        );
        assertLe(utilization, targetUtilization);
    }

    function test_deposit_oneUserMaxDeposit() public {
        // firstly accrue interest on the market to get accurate state of it in maxDeposit()
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
        MarketParams memory marketParams = MarketParams(
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
        markets.accrueInterest(marketParams);

        uint256 amountToDeposit = strategy.maxDeposit(alice);
        startHoax(alice);

        IWNative(wFlow).deposit{value: amountToDeposit}();
        assertEq(wFlow.balanceOf(alice), amountToDeposit);

        wFlow.approve(address(strategy), amountToDeposit);
        strategy.deposit(amountToDeposit, alice);

        assertEq(strategy.balanceOf(alice), amountToDeposit);
        assertApproxEqAbs(strategy.totalAssets(), amountToDeposit, 1e3);
        assertEq(
            strategy.convertToAssets(strategy.balanceOf(alice)),
            strategy.totalAssets()
        );

        Market memory market = markets.market(marketId);
        uint256 utilization = uint256(
            market.totalSupplyAssets > 0
                ? (market.totalBorrowAssets).wDivDown(market.totalSupplyAssets)
                : 0
        );
        assertLe(utilization, targetUtilization);
        assertApproxEqAbs(strategy.maxDeposit(alice), 0, 1e3);
    }

    function test_deposit_shouldRevertIfUtilizationExceedsTarget() public {
        uint256 amountToDeposit = MAX_TEST_DEPOSIT;
        startHoax(alice);
        IWNative(wFlow).deposit{value: amountToDeposit * 1e4}();
        assertEq(wFlow.balanceOf(alice), amountToDeposit * 1e4);

        wFlow.approve(address(strategy), amountToDeposit);
        strategy.deposit(amountToDeposit, alice);

        Market memory market = markets.market(marketId);
        uint256 utilization = uint256(
            market.totalSupplyAssets > 0
                ? (market.totalBorrowAssets).wDivDown(market.totalSupplyAssets)
                : 0
        );
        assertApproxEqAbs(utilization, targetUtilization, 1);

        uint256 amountToDepositSecond = 1 ether;
        startHoax(bob);
        IWNative(wFlow).deposit{value: amountToDepositSecond}();
        assertEq(wFlow.balanceOf(bob), amountToDepositSecond);

        wFlow.approve(address(strategy), amountToDepositSecond);
        vm.expectRevert(LoopStrategy.TargetUtilizationReached.selector);
        strategy.deposit(amountToDepositSecond, bob);
    }

    function test_deposit_twoUsersSharesMintedCorrectly(
        uint256 amountToDepositFirst,
        uint256 amountToDepositSecond
    ) public {
        vm.assume(amountToDepositFirst > MIN_TEST_DEPOSIT);
        vm.assume(amountToDepositFirst < MAX_TEST_DEPOSIT);
        vm.assume(amountToDepositSecond > MIN_TEST_DEPOSIT);
        vm.assume(amountToDepositSecond < MAX_TEST_DEPOSIT);

        startHoax(alice);
        IWNative(wFlow).deposit{value: amountToDepositFirst * 1e4}();
        assertEq(wFlow.balanceOf(alice), amountToDepositFirst * 1e4);

        // uint256 expectedMintedAmountAlice = strategy.previewDeposit(
        //     amountToDepositFirst
        // );
        wFlow.approve(address(strategy), amountToDepositFirst);
        strategy.deposit(amountToDepositFirst, alice);

        assertEq(strategy.balanceOf(alice), amountToDepositFirst);
        // assertEq(strategy.balanceOf(alice), expectedMintedAmountAlice);
        assertApproxEqAbs(strategy.totalAssets(), amountToDepositFirst, 1e3);
        assertEq(
            strategy.convertToAssets(strategy.balanceOf(alice)),
            strategy.totalAssets()
        );

        startHoax(bob);
        IWNative(wFlow).deposit{value: amountToDepositSecond * 1e4}();
        assertEq(wFlow.balanceOf(bob), amountToDepositSecond * 1e4);

        uint256 expectedMintedAmount = strategy.previewDeposit(
            amountToDepositSecond
        );
        wFlow.approve(address(strategy), amountToDepositSecond);

        // calculation of amount that will be supplied and borrowed
        uint256 toSupply = _calcAmountToSupplyAndBorrow(amountToDepositSecond);

        Market memory market = markets.market(marketId);
        uint256 utilization = uint256(
            market.totalSupplyAssets > 0
                ? (market.totalBorrowAssets + toSupply).wDivDown(
                    market.totalSupplyAssets + toSupply
                )
                : 0
        );
        if (utilization >= targetUtilization) {
            vm.expectRevert(LoopStrategy.TargetUtilizationReached.selector);
            strategy.deposit(amountToDepositSecond, bob);
        } else {
            strategy.deposit(amountToDepositSecond, bob);
            assertApproxEqAbs(
                strategy.balanceOf(bob),
                expectedMintedAmount,
                1e3
            );
            assertApproxEqAbs(
                strategy.totalAssets(),
                amountToDepositFirst + amountToDepositSecond,
                1e3
            );
            assertApproxEqAbs(
                strategy.convertToAssets(strategy.balanceOf(alice)) +
                    strategy.convertToAssets(strategy.balanceOf(bob)),
                strategy.totalAssets(),
                10
            );

            assertApproxEqAbs(
                strategy.balanceOf(bob),
                expectedMintedAmount,
                1e3
            );
            assertApproxEqAbs(
                strategy.totalAssets(),
                amountToDepositFirst + amountToDepositSecond,
                1e3
            );
            assertApproxEqAbs(
                strategy.convertToAssets(strategy.balanceOf(alice)) +
                    strategy.convertToAssets(strategy.balanceOf(bob)),
                strategy.totalAssets(),
                10
            );
        }
    }

    function test_deposit_twoUsersUtilizationShouldBeLessThanTarget(
        uint256 amountToDepositFirst,
        uint256 amountToDepositSecond
    ) public {
        vm.assume(amountToDepositFirst > MIN_TEST_DEPOSIT);
        vm.assume(amountToDepositFirst < MAX_TEST_DEPOSIT);
        vm.assume(amountToDepositSecond > MIN_TEST_DEPOSIT);
        vm.assume(amountToDepositSecond < MAX_TEST_DEPOSIT);

        startHoax(alice);
        IWNative(wFlow).deposit{value: amountToDepositFirst * 1e4}();

        wFlow.approve(address(strategy), amountToDepositFirst);
        strategy.deposit(amountToDepositFirst, alice);

        Market memory market = markets.market(marketId);
        uint256 utilization = uint256(
            market.totalSupplyAssets > 0
                ? (market.totalBorrowAssets).wDivDown(market.totalSupplyAssets)
                : 0
        );
        assertLe(utilization, targetUtilization);

        startHoax(bob);
        IWNative(wFlow).deposit{value: amountToDepositSecond * 1e4}();

        wFlow.approve(address(strategy), amountToDepositSecond);

        // calculation of amount that will be supplied and borrowed
        uint256 toSupply = _calcAmountToSupplyAndBorrow(amountToDepositSecond);

        market = markets.market(marketId);
        utilization = uint256(
            market.totalSupplyAssets > 0
                ? (market.totalBorrowAssets + toSupply).wDivDown(
                    market.totalSupplyAssets + toSupply
                )
                : 0
        );
        if (utilization >= targetUtilization) {
            vm.expectRevert(LoopStrategy.TargetUtilizationReached.selector);
            strategy.deposit(amountToDepositSecond, bob);
        } else {
            strategy.deposit(amountToDepositSecond, bob);

            market = markets.market(marketId);
            utilization = uint256(
                market.totalSupplyAssets > 0
                    ? (market.totalBorrowAssets).wDivDown(
                        market.totalSupplyAssets
                    )
                    : 0
            );
            assertLe(utilization, targetUtilization);
        }
    }

    function test_withdraw_fullWithdrawOneUser(uint256 amountToDeposit) public {
        vm.assume(amountToDeposit > MIN_TEST_DEPOSIT);
        vm.assume(amountToDeposit < MAX_TEST_DEPOSIT / 1e3);
        startHoax(alice);
        IWNative(wFlow).deposit{value: amountToDeposit * 1e4}();
        assertEq(wFlow.balanceOf(alice), amountToDeposit * 1e4);

        wFlow.approve(address(strategy), amountToDeposit);
        strategy.deposit(amountToDeposit, alice);

        assertEq(strategy.balanceOf(alice), amountToDeposit);
        assertApproxEqAbs(strategy.totalAssets(), amountToDeposit, 1e3);
        assertEq(
            strategy.convertToAssets(strategy.balanceOf(alice)),
            strategy.totalAssets()
        );

        (
            uint256 amountToRepay,
            uint256 wFlowAmount,
            uint256 ankrFlowAmount
        ) = strategy.expectedAmountsToWithdraw(
                strategy.convertToAssets(strategy.balanceOf(alice))
            );
        uint256 aliceClaimable = strategy.convertToAssets(
            strategy.balanceOf(alice)
        );

        uint256 ankrFlowBalanceBefore = ankrFlow.balanceOf(alice);
        uint256 wFlowBalanceBefore = wFlow.balanceOf(alice);

        (uint256 swapCost, ) = quoter.swapDesire(
            uint128(amountToRepay),
            defaultPath
        );

        strategy.redeem(strategy.balanceOf(alice), alice, alice);

        assertEq(strategy.balanceOf(alice), 0);
        assertLe(
            swapCost,
            ICertificateToken(ankrFlow).bondsToShares(amountToRepay) +
                aliceClaimable.wMulDown(swapMaxLossPercent)
        );
        assertEq(
            aliceClaimable,
            ankrFlow.sharesToBonds(ankrFlowAmount) + wFlowAmount - amountToRepay
        );
        assertLe(
            amountToDeposit.wMulDown(1e18 - swapMaxLossPercent),
            ankrFlow.sharesToBonds(ankrFlow.balanceOf(alice)) +
                wFlow.balanceOf(alice) -
                wFlowBalanceBefore
        );

        assertApproxEqAbs(
            ankrFlow.balanceOf(alice),
            ankrFlowBalanceBefore + ankrFlowAmount - swapCost,
            10
        );
        assertApproxEqAbs(
            wFlow.balanceOf(alice),
            wFlowBalanceBefore + wFlowAmount,
            10
        );

        Position memory position = markets.position(
            marketId,
            address(strategy)
        );
        assertEq(position.borrowShares, 0);
        assertEq(position.collateral, 0);
        assertEq(vault.balanceOf(address(strategy)), 0);
    }

    function test_withdraw_partialWithdrawOneUser(
        uint256 amountToDeposit,
        uint256 percentToWithdraw
    ) public {
        vm.assume(amountToDeposit > MIN_TEST_DEPOSIT);
        vm.assume(amountToDeposit < MAX_TEST_DEPOSIT / 1e3);
        percentToWithdraw = bound(percentToWithdraw, 0.001e18, 0.99e18);

        {
            startHoax(alice);
            IWNative(wFlow).deposit{value: amountToDeposit * 1e4}();
            assertEq(wFlow.balanceOf(alice), amountToDeposit * 1e4);

            wFlow.approve(address(strategy), amountToDeposit);
            strategy.deposit(amountToDeposit, alice);

            assertEq(strategy.balanceOf(alice), amountToDeposit);
            assertApproxEqAbs(strategy.totalAssets(), amountToDeposit, 1e3);
            assertEq(
                strategy.convertToAssets(strategy.balanceOf(alice)),
                strategy.totalAssets()
            );
        }

        uint256 amountToWithdraw = amountToDeposit.wMulDown(percentToWithdraw);

        (
            uint256 amountToRepay,
            uint256 wFlowAmount,
            uint256 ankrFlowAmount
        ) = strategy.expectedAmountsToWithdraw(amountToWithdraw);
        uint256 aliceSharesToBurn = strategy.convertToShares(amountToWithdraw);

        uint256 strategySharesBefore = strategy.balanceOf(alice);
        uint256 wFlowBalanceBefore = wFlow.balanceOf(alice);

        Position memory strategyPositionBefore = markets.position(
            marketId,
            address(strategy)
        );
        uint256 strategyVaultBalanceBefore = vault.balanceOf(address(strategy));

        uint256 totalBorrowSharesForMultiplier = markets
            .totalBorrowSharesForMultiplier(
                marketId,
                strategyPositionBefore.lastMultiplier
            );
        uint256 totalBorrowAssetsForMultiplier = markets
            .totalBorrowAssetsForMultiplier(
                marketId,
                strategyPositionBefore.lastMultiplier
            );

        (uint256 swapCost, ) = quoter.swapDesire(
            uint128(amountToRepay),
            defaultPath
        );
        strategy.withdraw(amountToWithdraw, alice, alice);

        assertApproxEqAbs(
            strategy.balanceOf(alice),
            strategySharesBefore - aliceSharesToBurn,
            10
        );
        assertLe(
            swapCost,
            ICertificateToken(ankrFlow).bondsToShares(amountToRepay) +
                amountToWithdraw.wMulDown(swapMaxLossPercent)
        );
        assertApproxEqAbs(
            amountToWithdraw,
            ankrFlow.sharesToBonds(ankrFlowAmount) +
                wFlowAmount -
                amountToRepay,
            1e4
        );
        assertLe(
            amountToDeposit.wMulDown(percentToWithdraw).wMulDown(
                1e18 - swapMaxLossPercent
            ),
            ankrFlow.sharesToBonds(ankrFlow.balanceOf(alice)) +
                wFlow.balanceOf(alice) -
                wFlowBalanceBefore
        );

        uint256 borrowSharesToRepay = amountToRepay.toSharesDown(
            totalBorrowAssetsForMultiplier,
            totalBorrowSharesForMultiplier
        );
        uint256 vaultSharesToWithdraw = vault.previewWithdraw(wFlowAmount);
        Position memory position = markets.position(
            marketId,
            address(strategy)
        );
        assertApproxEqAbs(
            position.borrowShares,
            strategyPositionBefore.borrowShares - borrowSharesToRepay,
            1e6
        );
        assertApproxEqAbs(
            position.collateral,
            strategyPositionBefore.collateral - ankrFlowAmount,
            1e3
        );
        assertApproxEqAbs(
            vault.balanceOf(address(strategy)),
            strategyVaultBalanceBefore - vaultSharesToWithdraw,
            1e3
        );
    }

    function test_withdraw_partialWithdrawOneUserThenFullWithdraw(
        uint256 amountToDeposit,
        uint256 percentToWithdraw
    ) public {
        vm.assume(amountToDeposit > MIN_TEST_DEPOSIT);
        vm.assume(amountToDeposit < MAX_TEST_DEPOSIT / 1e3);
        percentToWithdraw = bound(percentToWithdraw, 0.001e18, 0.99e18);
        test_withdraw_partialWithdrawOneUser(
            amountToDeposit,
            percentToWithdraw
        );

        (
            uint256 amountToRepay,
            uint256 wFlowAmount,
            uint256 ankrFlowAmount
        ) = strategy.expectedAmountsToWithdraw(
                strategy.convertToAssets(strategy.balanceOf(alice))
            );
        uint256 aliceClaimable = strategy.convertToAssets(
            strategy.balanceOf(alice)
        );

        uint256 ankrFlowBalanceBefore = ankrFlow.balanceOf(alice);
        uint256 wFlowBalanceBefore = wFlow.balanceOf(alice);

        (uint256 swapCost, ) = quoter.swapDesire(
            uint128(amountToRepay),
            defaultPath
        );

        strategy.redeem(strategy.balanceOf(alice), alice, alice);

        assertEq(strategy.balanceOf(alice), 0);
        assertLe(
            swapCost,
            ICertificateToken(ankrFlow).bondsToShares(amountToRepay) +
                aliceClaimable.wMulDown(swapMaxLossPercent)
        );

        assertApproxEqAbs(
            aliceClaimable,
            ankrFlow.sharesToBonds(ankrFlowAmount) +
                wFlowAmount -
                amountToRepay,
            1e4
        );

        assertLe(
            aliceClaimable.wMulDown(1e18 - swapMaxLossPercent),
            ankrFlow.sharesToBonds(ankrFlow.balanceOf(alice)) +
                wFlow.balanceOf(alice) -
                wFlowBalanceBefore
        );
        assertApproxEqAbs(
            ankrFlow.balanceOf(alice),
            ankrFlowBalanceBefore + ankrFlowAmount - swapCost,
            10
        );
        assertApproxEqAbs(
            wFlow.balanceOf(alice),
            wFlowBalanceBefore + wFlowAmount,
            10
        );
        Position memory position = markets.position(
            marketId,
            address(strategy)
        );

        assertEq(position.borrowShares, 0);
        assertEq(position.collateral, 0);
        assertEq(vault.balanceOf(address(strategy)), 0);
    }

    function test_withdraw_fullWithdrawOneUserWithCustomPath(
        uint256 amountToDeposit
    ) public {
        vm.assume(amountToDeposit > MIN_TEST_DEPOSIT);
        vm.assume(amountToDeposit < MAX_TEST_DEPOSIT / 1e3);

        startHoax(owner);
        swapMaxLossPercent *= 6;
        strategy.setSwapMaxLossPercent(swapMaxLossPercent);

        bytes memory customPath = abi.encodePacked(
            address(wFlow),
            uint24(3000),
            address(ankrFlow)
        );

        startHoax(alice);
        IWNative(wFlow).deposit{value: amountToDeposit * 1e4}();
        assertEq(wFlow.balanceOf(alice), amountToDeposit * 1e4);

        wFlow.approve(address(strategy), amountToDeposit);
        strategy.deposit(amountToDeposit, alice);

        assertEq(strategy.balanceOf(alice), amountToDeposit);
        assertApproxEqAbs(strategy.totalAssets(), amountToDeposit, 1e3);
        assertEq(
            strategy.convertToAssets(strategy.balanceOf(alice)),
            strategy.totalAssets()
        );

        (
            uint256 amountToRepay,
            uint256 wFlowAmount,
            uint256 ankrFlowAmount
        ) = strategy.expectedAmountsToWithdraw(
                strategy.convertToAssets(strategy.balanceOf(alice))
            );
        uint256 aliceClaimable = strategy.convertToAssets(
            strategy.balanceOf(alice)
        );

        uint256 ankrFlowBalanceBefore = ankrFlow.balanceOf(alice);
        uint256 wFlowBalanceBefore = wFlow.balanceOf(alice);

        (uint256 swapCost, ) = quoter.swapDesire(
            uint128(amountToRepay),
            customPath
        );

        strategy.redeem(strategy.balanceOf(alice), alice, alice, customPath);

        assertEq(strategy.balanceOf(alice), 0);
        assertLe(
            swapCost,
            ICertificateToken(ankrFlow).bondsToShares(amountToRepay) +
                aliceClaimable.wMulDown(swapMaxLossPercent)
        );
        assertEq(
            aliceClaimable,
            ankrFlow.sharesToBonds(ankrFlowAmount) + wFlowAmount - amountToRepay
        );
        assertLe(
            amountToDeposit.wMulDown(1e18 - swapMaxLossPercent),
            ankrFlow.sharesToBonds(ankrFlow.balanceOf(alice)) +
                wFlow.balanceOf(alice) -
                wFlowBalanceBefore
        );

        assertApproxEqAbs(
            ankrFlow.balanceOf(alice),
            ankrFlowBalanceBefore + ankrFlowAmount - swapCost,
            10
        );
        assertApproxEqAbs(
            wFlow.balanceOf(alice),
            wFlowBalanceBefore + wFlowAmount,
            10
        );

        Position memory position = markets.position(
            marketId,
            address(strategy)
        );
        assertEq(position.borrowShares, 0);
        assertEq(position.collateral, 0);
        assertEq(vault.balanceOf(address(strategy)), 0);
    }

    function test_deposit_defaultFeeShouldBeAppliedCorrectly() public {
        uint256 amountToDeposit = 1000 ether;
        startHoax(owner);
        uint256 feeToSet = 0.1e18;
        uint256 amountToDistribute = 10 ether;

        strategy.setFeeRecipient(owner);
        strategy.setFee(feeToSet);

        startHoax(alice);
        IWNative(wFlow).deposit{value: amountToDeposit * 1e4}();

        wFlow.approve(address(strategy), amountToDeposit);
        strategy.deposit(amountToDeposit, alice);

        IWNative(wFlow).transferFrom(
            alice,
            address(strategy),
            amountToDistribute
        );
        uint256 expectedDefaultFeeAmount = amountToDistribute
            .wMulDown(feeToSet)
            .wMulDown(1e18 - protocolFeePercent);
        uint256 expectedProtocolFeeAmount = amountToDistribute
            .wMulDown(feeToSet)
            .wMulDown(protocolFeePercent);

        uint256 secondAmountToDeposit = 100 ether;
        uint256 sharesToMint = strategy.previewDeposit(secondAmountToDeposit);
        wFlow.approve(address(strategy), secondAmountToDeposit + 1e2);
        strategy.mint(sharesToMint, alice);

        assertGt(strategy.balanceOf(owner), 0);
        assertEq(
            strategy.balanceOf(owner) +
                strategy.balanceOf(alice) +
                strategy.balanceOf(protocolFeeRecipient),
            strategy.totalSupply()
        );
        assertApproxEqAbs(
            strategy.convertToAssets(strategy.balanceOf(owner)) +
                strategy.convertToAssets(strategy.balanceOf(alice)) +
                strategy.convertToAssets(
                    strategy.balanceOf(protocolFeeRecipient)
                ),
            strategy.totalAssets(),
            1e3
        );
        assertApproxEqAbs(
            strategy.convertToAssets(strategy.balanceOf(owner)),
            expectedDefaultFeeAmount,
            1e3
        );
        assertApproxEqAbs(
            strategy.convertToAssets(strategy.balanceOf(protocolFeeRecipient)),
            expectedProtocolFeeAmount,
            1e3
        );
    }

    function _calcAmountToSupplyAndBorrow(
        uint256 assets
    ) internal view returns (uint256 toSupply) {
        // simulation deposit
        // calculating amount of deposit in ankrFlow
        uint256 depositAmountInAnkrFlow = ankrFlow.bondsToShares(assets);
        // calculating how much we should provide as collateral in ankrFlow
        uint256 toSupplyAsCollateral = depositAmountInAnkrFlow
            .wMulDown(100 * 1e18)
            .wDivDown(100 * 1e18 + (targetStrategyLtv.wMulDown(100 * 1e18)))
            .wMulDown(100 * 1e18)
            .wDivDown(100 * 1e18) - 1;
        // calcaulating how much should be provided as supply to the vault in FLOW
        toSupply = ankrFlow.sharesToBonds(
            toSupplyAsCollateral.wMulDown(targetStrategyLtv)
        );
    }
}
