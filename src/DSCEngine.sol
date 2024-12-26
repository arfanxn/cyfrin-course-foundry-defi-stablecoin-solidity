// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @dev A decentralized stablecoin contract.
 * @author Arfan
 *
 * The system is designed to be a minimal as possible, and have the tokens maintain a 1 token == $1 peg
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the value of all the DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC, as
 * well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /***************************************************
     * Error
     ***************************************************/
    error DSCEngine__TransferFailed();
    error DSCEngine__RequiresGraterThanZero();
    error DSCEngine__TokenIsntAllowed();
    error DSCEngine__TokenAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /***************************************************
     * Types
     ***************************************************/
    using OracleLib for AggregatorV3Interface;

    /***************************************************
     * States
     ***************************************************/

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% liquidation bonus
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDSCminted) private s_DSCMinted;
    address[] private s_collateralTokens;

    /***************************************************
     * Events
     ***************************************************/

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed reedemedFrom,
        address indexed reedemedTo,
        address indexed token,
        uint256 amount
    );

    /***************************************************
     * Modifiers
     ***************************************************/

    modifier onlyGTZero(uint256 amount) {
        if (amount <= 0) revert DSCEngine__RequiresGraterThanZero();
        _;
    }

    modifier onlyAllowedToken(address tokenAddr) {
        if (s_priceFeeds[tokenAddr] == address(0)) {
            revert DSCEngine__TokenIsntAllowed();
        }
        _;
    }

    /***************************************************
     * Public and External functions
     ***************************************************/

    constructor(
        address[] memory tokenAddrs,
        address[] memory priceFeedAddrs,
        address dscAddr
    ) {
        if (tokenAddrs.length != priceFeedAddrs.length) {
            revert DSCEngine__TokenAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 index = 0; index < tokenAddrs.length; index++) {
            s_priceFeeds[tokenAddrs[index]] = priceFeedAddrs[index];
            s_collateralTokens.push(tokenAddrs[index]);
        }

        i_dsc = DecentralizedStableCoin(dscAddr);
    }

    /**
     * @param collateralTokenAddr The address of the token to deposit as collateral.
     * @param collateralAmount The amount of collateral to deposit.
     */
    function depositCollateral(
        address collateralTokenAddr,
        uint256 collateralAmount
    )
        public
        onlyGTZero(collateralAmount)
        onlyAllowedToken(collateralTokenAddr)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            collateralTokenAddr
        ] += collateralAmount;
        emit CollateralDeposited(
            msg.sender,
            collateralTokenAddr,
            collateralAmount
        );
        bool success = IERC20(collateralTokenAddr).transferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );

        if (!success) revert DSCEngine__TransferFailed();
    }

    function reedemCollateral(
        address collateralTokenAddr,
        uint256 collateralAmount
    ) public onlyGTZero(collateralAmount) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            collateralTokenAddr,
            collateralAmount
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param dscAmount The amount of DSC to mint
     */
    function mintDSC(
        uint256 dscAmount
    ) public onlyGTZero(dscAmount) nonReentrant {
        s_DSCMinted[msg.sender] += dscAmount;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, dscAmount);
        if (!minted) revert DSCEngine__MintFailed();
    }

    /**
     * @param dscAmount The amount of DSC to burn
     */
    function burnDSC(uint256 dscAmount) public onlyGTZero(dscAmount) {
        _burnDSC(dscAmount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // i dont think this would be needed
    }

    /**
     * @param collateralTokenAddr The address of the collateral token.
     * @param collateralAmount The amount of collateral.
     * @param dscAmount The amount of DSC to burn.
     *
     * this function burns DSC and reedems underlying collateral in a single transaction
     */
    function reedemCollateralForDSC(
        address collateralTokenAddr,
        uint256 collateralAmount,
        uint256 dscAmount
    ) external {
        burnDSC(dscAmount);
        reedemCollateral(collateralTokenAddr, collateralAmount); // the reedemCollateral function already checks health factor
    }

    /**
     *
     * @param collateralTokenAddr the ERC20 address of the collateral to be liquidated
     * @param liquidatedAddr the liquidated user address (which has low health factor)
     * @param debtToCover the amount of DSC u want to burn to improve the user's health factor
     * @notice u can partially liqudate a user
     * @notice u will get a liquidation bonus for taking users' funds
     * @notice this function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice a known bug would be if the protocol were 100% or undercollateralized, then we wouldn't be able to incentives the liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated, then the protocol would be undercollateralized
     */
    function liquidate(
        address collateralTokenAddr,
        address liquidatedAddr,
        uint256 debtToCover
    ) external onlyGTZero(debtToCover) nonReentrant {
        address liquidatorAddr = msg.sender;
        uint256 startingHealthFactor = _healthFactor(liquidatedAddr);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(
            collateralTokenAddr,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToReedem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            liquidatedAddr, // the liquidated user's address
            liquidatorAddr,
            collateralTokenAddr,
            totalCollateralToReedem
        );
        _burnDSC(debtToCover, liquidatedAddr, liquidatorAddr);

        uint256 endingHealthFactor = _healthFactor(liquidatedAddr);
        if (endingHealthFactor <= startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(liquidatorAddr);
    }

    function getHealthFactor(address userAddr) external view returns (uint256) {
        return _healthFactor(userAddr);
    }

    function getAccountInformation(
        address userAddr
    )
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        (totalDSCMinted, collateralValueInUSD) = _getAccountInformation(
            userAddr
        );
    }

    function getTokenAmountFromUSD(
        address collateralTokenAddr,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[collateralTokenAddr]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // ($10e18 * 1e18) / (2000e8 * 1e10)
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValueInUSD(
        address user
    ) public view returns (uint256 totalCollateralInUSD) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUSD += getUSDValue(token, amount);
        }
        return totalCollateralInUSD;
    }

    function getUSDValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function depositCollateralAndMintDSC(
        address collateralTokenAddr,
        uint256 collateralAmount,
        uint256 amountDscToMint
    ) external {
        depositCollateral(collateralTokenAddr, collateralAmount);
        mintDSC(amountDscToMint);
    }

    /***************************************************
     * Private and Internal functions
     ***************************************************/

    /**
     *
     * @param amount the amount of DSC to burn
     * @param onBehalfOf the user who is burning DSC
     * @param dscFrom the user who is giving DSC
     */
    function _burnDSC(
        uint256 amount,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amount;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    function _redeemCollateral(
        address from,
        address to,
        address collateralTokenAddr,
        uint256 collateralAmount
    ) private {
        s_collateralDeposited[from][collateralTokenAddr] -= collateralAmount;
        emit CollateralRedeemed(
            from,
            to,
            collateralTokenAddr,
            collateralAmount
        );
        bool success = IERC20(collateralTokenAddr).transfer(
            to,
            collateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDSCMinted, uint256 totalCollateralInUSD)
    {
        totalDSCMinted = s_DSCMinted[user];
        totalCollateralInUSD = getAccountCollateralValueInUSD(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     *
     */
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDSCMinted,
            uint256 totalCollateralInUSD
        ) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (totalCollateralInUSD *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check health factor (do they have enough collateral?)
        // 2. revert if the don't
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR)
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }
}
