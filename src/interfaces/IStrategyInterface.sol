// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ILenderBorrower} from "./ILenderBorrower.sol";

interface IStrategyInterface is ILenderBorrower {
    function openTrove(uint256 _upperHint, uint256 _lowerHint, address _sugardaddy) external;
}
