// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    function openTrove(uint256 _upperHint, uint256 _lowerHint, address _sugardaddy) external;
}
