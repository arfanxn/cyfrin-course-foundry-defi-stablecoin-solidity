// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelperConfig public config;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        DeployDSCEngine deployer = new DeployDSCEngine();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();

        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
    }

    address[] public tokenAddrs;
    address[] public priceFeedAddrs;

    function testRevertsIfTokenLength() public {
        tokenAddrs.push(weth);
        priceFeedAddrs.push(ethUsdPriceFeed);
        priceFeedAddrs.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAndPriceFeedAddressesMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddrs, priceFeedAddrs, address(dsc));
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUSD = 30_000e18;
        uint256 actualUSD = engine.getUSDValue(weth, ethAmount);
        assertEq(expectedUSD, actualUSD);
    }

    function testGetTokenAmountFromUSD() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUSD(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__RequiresGraterThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        vm.startPrank(user);
        ERC20Mock ranToken = new ERC20Mock(
            "Ran",
            "RAN",
            user,
            STARTING_USER_BALANCE
        );
        vm.expectRevert(DSCEngine.DSCEngine__TokenIsntAllowed.selector);
        engine.depositCollateral(address(ranToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine
            .getAccountInformation(user);
        uint256 expectedTotalDSCMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUSD(
            weth,
            collateralValueInUSD
        );

        assertEq(totalDSCMinted, expectedTotalDSCMinted);
        assertEq(amountCollateral, expectedDepositAmount);
    }
}
