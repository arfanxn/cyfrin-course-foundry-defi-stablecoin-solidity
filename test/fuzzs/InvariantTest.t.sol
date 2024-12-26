// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Handler} from "./Handler.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvariantTest is StdInvariant, Test {
    DeployDSCEngine public deployer;
    DSCEngine public dscEngine;
    DecentralizedStableCoin public dsc;
    HelperConfig public config;
    address public weth;
    address public wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSCEngine();
        (dsc, dscEngine, config) = deployer.run();
        (, , weth, wbtc, ) = config.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsc));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsc));

        uint256 wethInUSD = dscEngine.getUSDValue(weth, totalWethDeposited);
        uint256 wbtcInUSD = dscEngine.getUSDValue(wbtc, totalWbtcDeposited);

        assert((wethInUSD + wbtcInUSD) >= totalSupply);
    }
}
