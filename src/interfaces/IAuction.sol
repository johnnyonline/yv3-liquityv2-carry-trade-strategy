// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IAuction {
    function kick(address _token) external returns (uint256);
    function setStartingPrice(
        uint256 _startingPrice
    ) external;
    function enable(address _from) external;
}
