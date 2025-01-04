// SPDX-License-Identfier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressesAndPriceFeedsLengthMismatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000e8 * 1e10 = 30000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////
    // Deposit Collateral //
    ////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        mockDsc.approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, 0);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    ///////////////////////
    // Mint DSC Tests   //
    //////////////////////

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 10 ETH collateral = 20,000$ (ETH price is 2000$)
        // 50% liquidation threshold means can borrow 10,000$
        // Try to mint 11,000$ DSC which should revert
        vm.startPrank(USER);

        // 20,000 * 50 = 1,000,000 / 1000 = 10,000 (maximum amount we can mint)
        uint256 collateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        uint256 amountToMint = maxDscToMint + 1 ether; // More than max allowed

        // Calculate expected health factor for this amount
        uint256 expectedHealthFactor = (collateralValueInUsd * LIQUIDATION_THRESHOLD * 1e18) / (amountToMint * 100);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(1 ether);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 1 ether);
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1 ether);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(1 ether);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 1 ether);
    }

    ///////////////////////
    // Burn DSC Tests   //
    //////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 1 ether);
        dsce.burnDsc(1 ether);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        uint256 collateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 amountToMint = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100 + 1;
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 
            (collateralValueInUsd * LIQUIDATION_THRESHOLD * 1e18) / (amountToMint * 100)));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1 ether);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 1 ether);
    }

    ////////////////////////////////////
    // redeemCollateral Tests //////////
    ////////////////////////////////////

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountGreaterThanCollateral() public {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.redeemCollateral(weth, 1);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testEmitsCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true, address(dsce));
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // redeemCollateralForDsc Tests ///
    ////////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, 1 ether);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 1 ether);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, 1 ether);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);
    }

    ////////////////////////
    // Liquidation Tests //
    //////////////////////

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorOkay.selector, dsce.getHealthFactor(USER)));
        dsce.liquidate(weth, USER, 1 ether);
        vm.stopPrank();
    }

    function testLiquidationPayoutIsCorrect() public {
        // SETUP PHASE
        // User has 10 ETH at $2000/ETH = $20,000 total collateral
        // User mints 5000 DSC (less than the 50% max LTV which would be $10,000)
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18);
        vm.stopPrank();

        // Price drops to $1000/ETH
        // 10 ETH * $1000 = $10,000 total collateral
        // 5000 DSC is now at the maximum LTV of 50%
        // Any further drop will put them in liquidation territory
        int256 ethUsdUpdatedPrice = 1000e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Price drops to $800/ETH
        // 10 ETH * $800 = $8,000 total collateral
        // 5000 DSC with $8,000 collateral is below the 50% LTV threshold
        ethUsdUpdatedPrice = 800e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        
        uint256 userHealthFactorBefore = dsce.getHealthFactor(USER);

        // Setup liquidator with 1000 DSC to do the liquidation
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000e18);
        dsc.approve(address(dsce), 1000e18);

        // Liquidate 1000 DSC debt
        uint256 liquidatorWethBalanceBefore = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        dsce.liquidate(weth, USER, 1000e18); // Liquidate 1000 DSC
        uint256 liquidatorWethBalanceAfter = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        vm.stopPrank();

        // Calculate expected ETH payout
        // At $800/ETH, 1000 DSC = 1.25 ETH
        // 10% bonus = 1.375 ETH total
        uint256 expectedWeth = 1.375 ether;
        uint256 actualWeth = liquidatorWethBalanceAfter - liquidatorWethBalanceBefore;
        assertEq(actualWeth, expectedWeth);
    }

    function testLiquidationImproveHealthFactor() public {
        // Same setup as above
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18);
        vm.stopPrank();

        // Drop price to $800/ETH
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(800e8);
        
        uint256 userHealthFactorBefore = dsce.getHealthFactor(USER);

        // Setup liquidator
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000e18);
        dsc.approve(address(dsce), 1000e18);

        // Liquidate
        dsce.liquidate(weth, USER, 1000e18);
        vm.stopPrank();

        uint256 userHealthFactorAfter = dsce.getHealthFactor(USER);
        assertGt(userHealthFactorAfter, userHealthFactorBefore);
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 5000e18);
        vm.stopPrank();
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(800e8);
        _;
    }

       function testCantLiquidateNonExistentCollateral() public {
        // Setup a random token that isn't registered as collateral
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", USER, 1 ether);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        dsce.depositCollateral(address(randToken), 1 ether);
        vm.stopPrank();
    }

    function testLiquidationImpossibleIfHealthFactorOkay() public depositedCollateralAndMintedDsc {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).mint(LIQUIDATOR, AMOUNT_COLLATERAL);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1 ether);
        dsc.approve(address(dsce), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorOkay.selector, dsce.getHealthFactor(USER)));
        dsce.liquidate(weth, USER, 1 ether);
        vm.stopPrank();
    }

    ////////////////////////////////////
    // View & Pure Function Tests //////
    ////////////////////////////////////

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 balance = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(balance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedValue);
    }

    function testGetDsc() public {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    ////////////////////////
    // Helper Functions ////
    ////////////////////////

    function helperDepositCollateral(address user, address token, uint256 amount) internal {
        vm.startPrank(user);
        ERC20Mock(token).approve(address(dsce), amount);
        dsce.depositCollateral(token, amount);
        vm.stopPrank();
    }

    function helperGetCollateralValue(address token, uint256 amount) internal view returns (uint256) {
        return dsce.getUsdValue(token, amount);
    }

    function testGetCollateralBalances() public depositedCollateral {
        uint256 balance = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(balance, AMOUNT_COLLATERAL);
    }

    ////////////////////////////////////
    // Additional Liquidation Tests ////
    ////////////////////////////////////
    
    function testCantLiquidateZeroDebt() public liquidated {
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000e18);
        dsc.approve(address(dsce), 1000e18);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.liquidate(weth, USER, 0);
        vm.stopPrank();
    }

        function testCantLiquidateMoreThanUserDebt() public {
        // USER setup: 10 ETH at $2000/ETH = $20,000 collateral
        // Mints only 1000 DSC (very safe)
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000e18);
        vm.stopPrank();

        // Price drops to $800/ETH
        // 10 ETH * $800 = $8,000 total collateral
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(800e8);

        // Liquidator setup: also 10 ETH, mint only 500 DSC
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 500e18);
        dsc.approve(address(dsce), 500e18);

        // Try to liquidate more than user's debt (1000 DSC)
        vm.expectRevert();
        dsce.liquidate(weth, USER, 1100e18); // Try to liquidate more than they have
        vm.stopPrank();
    }

    
    
    ///////////////////////////////////////
    // Test Multiple Collateral Types /////
    ///////////////////////////////////////

    function testCanDepositMultipleCollateralTypes() public {
        // Approve and deposit WETH
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        
        // Approve and deposit WBTC
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        uint256 expectedTotalCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) + 
                                             dsce.getUsdValue(wbtc, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedTotalCollateralValue);
    }

    function testCanMintWithMultipleCollateralTypes() public {
        // Deposit both WETH and WBTC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtc, AMOUNT_COLLATERAL);

        // Calculate total collateral value and mint DSC
        uint256 totalCollateralValue = dsce.getAccountCollateralValue(USER);
        uint256 mintAmount = (totalCollateralValue * 50) / 100; // 50% of collateral value
        dsce.mintDsc(mintAmount);
        vm.stopPrank();

        assertEq(dsc.balanceOf(USER), mintAmount);
    }

    ///////////////////////////////////////
    // Test Redemption Edge Cases /////////
    ///////////////////////////////////////

    function testRedeemCollateralForZeroDsc() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, 0);
        vm.stopPrank();
    }

    function testRedeemZeroCollateralForDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 1);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, 1);
        vm.stopPrank();
    }

    ////////////////////////////////////////
    // Test Price Feed Updates ////////////
    //////////////////////////////////////

    function testPriceDropScenario() public {
        // Setup: 10 ETH at $2000/ETH = $20,000 collateral
        // Mint 8000 DSC (more aggressive)
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 8000e18);
        vm.stopPrank();

        uint256 initialHealthFactor = dsce.getHealthFactor(USER);
        
        // Price drops to $800/ETH
        // 10 ETH * $800 = $8,000 collateral value
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(800e8);
        uint256 healthFactorAfterFirstDrop = dsce.getHealthFactor(USER);
        
        // Price drops to $200/ETH (very severe drop)
        // 10 ETH * $200 = $2,000 collateral value
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(200e8);
        uint256 healthFactorAfterSecondDrop = dsce.getHealthFactor(USER);

        assertGt(initialHealthFactor, 1e18);
        assertLt(healthFactorAfterSecondDrop, 1e18);
    }


    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountInformation() public depositedCollateralAndMintedDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 1 ether);
        assertEq(collateralValueInUsd, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
    }
}
