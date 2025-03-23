// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IBorrowerOperations} from "./IBorrowerOperations.sol";
import {ITroveManager} from "./ITroveManager.sol";

interface IAddressesRegistry {

    function collToken() external view returns (address);
    function boldToken() external view returns (address);
    function borrowerOperations() external view returns (IBorrowerOperations);
    function troveManager() external view returns (ITroveManager);

}
