// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) public {
        dscEngine = _dscEngine;
        dsc = _dsc;

        // address[] memory collateralTokens = dscEngine.getCollateralTokens();
    }

    function depositCollateral(
        address collateralTokenAddr,
        uint256 collateralAmount
    ) public {
        dscEngine.depositCollateral(collateralTokenAddr, collateralAmount);
    }
}
