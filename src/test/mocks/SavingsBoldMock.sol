// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20, ERC20, ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract SavingsBoldMock is ERC4626 {
    address public immutable COLL;

    constructor(address _asset, address _collateral) ERC4626(IERC20(_asset)) ERC20("Savings BOLD", "sBOLD") {
        COLL = _collateral;
    }
}
