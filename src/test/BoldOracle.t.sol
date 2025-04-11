// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup} from "./utils/Setup.sol";

contract BoldOracleTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_boldOracle() public {
        assertEq(boldOracle.decimals(), 18);
        assertEq(boldOracle.version(), 1);
        assertEq(boldOracle.description(), "BOLD/USD Price Feed");
        int256 latestAnswer = boldOracle.latestAnswer();
        assertRelApproxEq(uint256(latestAnswer), 1e18, 1);
        console2.log("latestAnswer", uint256(latestAnswer));
        (, int256 price,,,) = boldOracle.latestRoundData();
        assertEq(uint256(price), uint256(latestAnswer));
    }
}
