// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface ILiquityV2SPStrategy {

    function COLL() external view returns (address);
    function asset() external view returns (address);

}
