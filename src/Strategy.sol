// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAddressesRegistry, IBorrowerOperations, ITroveManager} from "./interfaces/IAddressesRegistry.sol";
import {ILiquityV2SPStrategy} from "./interfaces/ILiquityV2SPStrategy.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

import {BaseLenderBorrower} from "./BaseLenderBorrower.sol";

// @todo -- liquidation kills vault? can we _openTrove again?
// @todo -- what happens on zombie trove?
// @todo -- _emergencyWithdraw?
// @todo -- after a redemption (when have > owe (`have` being usa.d)) -- auction off `extra = have - owe;` back to asset (crvusd)
// @dev -- reporting will be blocked by healthCheck after a redemption, until the auction is complete
contract LiquityV2CarryTradeStrategy is BaseLenderBorrower {
    using SafeERC20 for ERC20;

    // NOTES:
    // 1. asset -- scrvUSD
    // 2. borrow token -- USA.d
    // 3. lender vault -- yvLiquityV2SP

    struct AssetInfo {
        uint256 heartbeat;
        IPriceFeed priceFeed;
    }

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Trove ID
    uint256 public troveId;

    /// @notice Asset info
    mapping(address asset => AssetInfo info) public assetInfo;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice `_getPrice` returns the price of the asset with 18 decimals
    uint256 public constant PRICE_FEED_DECIMALS = 18;

    /// @notice Any amount below this will be ignored
    uint256 public constant DUST_THRESHOLD = 10_000;

    /// @notice Liquity's minimum amount of net Bold debt a trove must have
    ///         If a trove is redeeemed and the debt is less than this, it will be considered a zombie trove
    uint256 public constant MIN_DEBT = 2_000 * 1e18;

    /// @notice Liquity's amount of WETH to be locked in gas pool when opening a trove
    ///         Will be pulled from the contract on `_openTrove`
    uint256 public constant ETH_GAS_COMPENSATION = 0.0375 ether;

    /// @notice Minimum annual interest rate
    uint256 public constant MIN_ANNUAL_INTEREST_RATE = 1e18 / 100 / 2; // 0.5%

    /// @notice WETH token
    ERC20 private constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    /// @notice Liquity's borrower operations contract
    IBorrowerOperations public immutable BORROWER_OPERATIONS;

    /// @notice Liquity's trove manager contract
    ITroveManager public immutable TROVE_MANAGER;

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor(
        address _asset,
        string memory _name,
        address _borrowToken,
        address _lenderVault,
        address _addressesRegistry
    ) BaseLenderBorrower(_asset, _name, _borrowToken, _lenderVault) {
        ILiquityV2SPStrategy lenderVault_ = ILiquityV2SPStrategy(_lenderVault);
        require(lenderVault_.COLL() == _asset && lenderVault_.asset() == _borrowToken, "!_lenderVault");

        IAddressesRegistry addressesRegistry_ = IAddressesRegistry(_addressesRegistry);
        require(addressesRegistry_.collToken() == _asset && addressesRegistry_.boldToken() == _borrowToken, "!_addressesRegistry");
        BORROWER_OPERATIONS = addressesRegistry_.borrowerOperations();
        TROVE_MANAGER = addressesRegistry_.troveManager();

        asset.forceApprove(address(BORROWER_OPERATIONS), type(uint256).max);
        WETH.forceApprove(address(BORROWER_OPERATIONS), ETH_GAS_COMPENSATION);
    }

    // ===============================================================
    // Management functions
    // ===============================================================

    /// @notice Set asset info
    /// @param _heartbeat Heartbeat
    /// @param _asset Asset address
    /// @param _priceFeed Price feed
    function setAssetInfo(uint256 _heartbeat, address _asset, address _priceFeed) external onlyManagement {
        require(_heartbeat <= 1 days, "heartbeat");

        (, int256 _answer, , uint256 _updatedAt, ) = IPriceFeed(_priceFeed).latestRoundData();
        require(_answer > 0 && _updatedAt > block.timestamp - _heartbeat, "stale");
        assetInfo[_asset] = AssetInfo(_heartbeat, IPriceFeed(_priceFeed));
    }

    /// @notice Opens a trove
    /// @dev `asset` balance must be large enough to open a trove with `MIN_DEBT`
    /// @dev Borrowing at the minimum interest rate because we don't mind getting redeeemed
    /// @dev ETH_GAS_COMPENSATION amount of WETH needs to be sent to the contract prior to calling this function
    /// @dev For hints, see https://github.com/liquity/bold?tab=readme-ov-file#trove-operation-with-hints
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    function openTrove(uint256 _upperHint, uint256 _lowerHint) external onlyManagement {
        require(troveId == 0, "troveId");
        troveId = BORROWER_OPERATIONS.openTrove(
            address(this), // _owner
            0, // _ownerIndex
            asset.balanceOf(address(this)), // _collAmount
            MIN_DEBT, // _boldAmount
            _upperHint,
            _lowerHint,
            MIN_ANNUAL_INTEREST_RATE, // _annualInterestRate
            type(uint256).max, // _maxUpfrontFee
            address(0), // _addManager
            address(0), // _removeManager
            address(0) // _receiver
        );
    }

    // ===============================================================
    // Internal write functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _deployFunds(uint256 _amount) internal override {
        if (troveId != 0) _leveragePosition(_amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _supplyCollateral(uint256 _amount) internal override {
        if (_amount > DUST_THRESHOLD) BORROWER_OPERATIONS.addColl(troveId, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _withdrawCollateral(uint256 _amount) internal override {
        BORROWER_OPERATIONS.withdrawColl(troveId, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _borrow(uint256 _amount) internal override {
        BORROWER_OPERATIONS.withdrawBold(troveId, _amount, type(uint256).max);
    }

    /// @inheritdoc BaseLenderBorrower
    function _repay(uint256 _amount) internal override {
        if (_amount > 0) BORROWER_OPERATIONS.repayBold(troveId, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _emergencyWithdraw(uint256 _amount) internal override {
        // borrowerOperations.closeTrove(uint256 _troveId)
    }

    // ===============================================================
    // Internal view functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _getPrice(address _asset) internal view override returns (uint256 price) {
        AssetInfo memory _info = assetInfo[_asset];
        require(address(_info.priceFeed) != address(0), "!_priceFeed");
        (, int256 _answer, , uint256 _updatedAt, ) = _info.priceFeed.latestRoundData();
        require(_answer > 0 && _updatedAt > block.timestamp - _info.heartbeat, "stale");
        uint256 _decimals = _info.priceFeed.decimals();
        return _decimals < PRICE_FEED_DECIMALS ? uint256(_answer) * (WAD / 10 ** _decimals) : uint256(_answer);
    }

    /// @inheritdoc BaseLenderBorrower
    function _isSupplyPaused() internal view override returns (bool) { // @todo -- here
        // * @notice Checks if lending or borrowing is paused
        // * @return True if paused, false otherwise
    }

    /// @inheritdoc BaseLenderBorrower
    function _isBorrowPaused() internal view override returns (bool) {
        // * @notice Checks if borrowing is paused
        // * @return True if paused, false otherwise
    }

    /// @inheritdoc BaseLenderBorrower
    function _isLiquidatable() internal view override returns (bool) {
        // * @notice Checks if the strategy is liquidatable
        // * @return True if liquidatable, false otherwise
    }

    /// @inheritdoc BaseLenderBorrower
    function _maxCollateralDeposit() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc BaseLenderBorrower
    function _maxBorrowAmount() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetBorrowApr(uint256 newAmount) public view override returns (uint256) {
        // * @notice Gets net borrow APR from depositor
        // * @param newAmount Simulated supply amount
        // * @return Net borrow APR
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(uint256 newAmount) public view override returns (uint256) {
        // * @notice Gets net reward APR from depositor
        // * @param newAmount Simulated supply amount
        // * @return Net reward APR
    }

    /// @inheritdoc BaseLenderBorrower
    function getLiquidateCollateralFactor() public view override returns (uint256) {
        // * @notice Gets liquidation collateral factor for asset
        // * @return Liquidation collateral factor
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfCollateral() public view override returns (uint256) {
        // * @notice Gets supplied collateral balance
        // * @return Collateral balance
    //     struct LatestTroveData {
    //     uint256 entireDebt;
    //     uint256 entireColl;
    //     uint256 redistBoldDebtGain;
    //     uint256 redistCollGain;
    //     uint256 accruedInterest;
    //     uint256 recordedDebt;
    //     uint256 annualInterestRate;
    //     uint256 weightedRecordedDebt;
    //     uint256 accruedBatchManagementFee;
    //     uint256 lastInterestRateAdjTime;
    // }
        // TROVE_MANAGER.getLatestTroveData
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfDebt() public view override returns (uint256) {
        // * @notice Gets current borrow balance
        // * @return Borrow balance
    }

    // ===============================================================
    // Harvest / Token conversions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _claimRewards() internal override {
        // * @notice Claims reward tokens.
    }

    /// @inheritdoc BaseLenderBorrower
    function _claimAndSellRewards() internal override {
        // * @notice Claims and sells available reward tokens
        // * @dev Handles claiming, selling rewards for borrow tokens if needed, and selling remaining rewards for asset
    }

    /// @inheritdoc BaseLenderBorrower
    function _buyBorrowToken() internal override {
        // * @dev Buys the borrow token using the strategy's assets.
        // * This function should only ever be called when withdrawing all funds from the strategy if there is debt left over.
        // * Initially, it tries to sell rewards for the needed amount of base token, then it will swap assets.
        // * Using this function in a standard withdrawal can cause it to be sandwiched, which is why rewards are used first.
    }

    /// @inheritdoc BaseLenderBorrower
    function _sellBorrowToken(uint256 _amount) internal override {
        // * @dev Will swap from the base token => underlying asset.
    }
}
