// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IPriceProvider {
    function getPrice(address _asset) external view returns (uint256 price);
}
