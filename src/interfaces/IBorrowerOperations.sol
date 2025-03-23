// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IBorrowerOperations {

    function openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _collAmount,
        uint256 _boldAmount,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _annualInterestRate,
        uint256 _maxUpfrontFee,
        address _addManager,
        address _removeManager,
        address _receiver
    ) external returns (uint256);
    function addColl(uint256 _troveId, uint256 _collAmount) external;
    function withdrawColl(uint256 _troveId, uint256 _amount) external;
    function repayBold(uint256 _troveId, uint256 _boldAmount) external;
    function withdrawBold(uint256 _troveId, uint256 _amount, uint256 _maxFee) external;

}
