// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAddressesRegistry, IBorrowerOperations, ITroveManager} from "./interfaces/IAddressesRegistry.sol";
import {ILiquityV2SPStrategy} from "./interfaces/ILiquityV2SPStrategy.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IAuction, IAuctionFactory} from "./interfaces/IAuctionFactory.sol";

import {BaseLenderBorrower, Math} from "./BaseLenderBorrower.sol";

// NOTES:
// 1. asset -- scrvUSD
// 2. borrow token -- USA.d
// 3. lender vault -- yvLiquityV2SP

// @todo -- liquidation kills vault? can we _openTrove again?
// @todo -- what happens on zombie trove?
// @todo -- _emergencyWithdraw?
// @todo -- after a redemption (when have > owe (`have` being usa.d)) -- auction off `extra = have - owe;` back to asset (crvusd)
// @dev -- stratagiest will need to deploy enough funds to open a trove after deployment
// @dev -- last withdrawal may be stuck until a shutdown (due to Liquity's minimum debt requirement)
// @dev -- will probably not use a factory here -- deploy manually
// @dev -- reporting will be blocked by healthCheck after a redemption, until the auction is complete
contract LiquityV2CarryTradeStrategy is BaseLenderBorrower {
    using SafeERC20 for ERC20;

    // ===============================================================
    // Structs
    // ===============================================================

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

    /// @notice Factory for creating the auction contract
    IAuctionFactory public constant AUCTION_FACTORY = IAuctionFactory(0xCfA510188884F199fcC6e750764FAAbE6e56ec40);

    /// @notice Auction contract for asset -> borrow token
    IAuction public immutable ASSET_TO_BORROW_AUCTION;

    /// @notice Auction contract for borrow token -> asset
    IAuction public immutable BORROW_TO_ASSET_AUCTION;

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
        require(
            addressesRegistry_.collToken() == _asset && addressesRegistry_.boldToken() == _borrowToken,
            "!_addressesRegistry"
        );
        BORROWER_OPERATIONS = addressesRegistry_.borrowerOperations();
        TROVE_MANAGER = addressesRegistry_.troveManager();

        ASSET_TO_BORROW_AUCTION = AUCTION_FACTORY.createNewAuction(_borrowToken);
        ASSET_TO_BORROW_AUCTION.enable(_asset);

        BORROW_TO_ASSET_AUCTION = AUCTION_FACTORY.createNewAuction(_asset);
        BORROW_TO_ASSET_AUCTION.enable(_borrowToken);

        asset.forceApprove(address(BORROWER_OPERATIONS), type(uint256).max);
        WETH.forceApprove(address(BORROWER_OPERATIONS), type(uint256).max);
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

        (, int256 _answer,, uint256 _updatedAt,) = IPriceFeed(_priceFeed).latestRoundData();
        require(_answer > 0 && _updatedAt > block.timestamp - _heartbeat, "stale");
        assetInfo[_asset] = AssetInfo(_heartbeat, IPriceFeed(_priceFeed));
    }

    /// @notice Opens a trove
    /// @dev Must be called after the strategy has been deployed, otherwise it will be unuseable
    /// @dev `asset` balance must be large enough to open a trove with `MIN_DEBT`
    /// @dev Borrowing at the minimum interest rate because we don't mind getting redeeemed
    /// @dev For hints, see https://github.com/liquity/bold?tab=readme-ov-file#trove-operation-with-hints
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    /// @param _sugardaddy ty sugardaddy
    function openTrove(uint256 _upperHint, uint256 _lowerHint, address _sugardaddy) external onlyManagement {
        WETH.safeTransferFrom(_sugardaddy, address(this), ETH_GAS_COMPENSATION);
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
    // Emergency authorized functions
    // ===============================================================

    /// @notice Buy borrow token
    /// @dev Calling this function will try to buy the full amount of the remaining debt
    ///      This may be necessary to unlock full collateral in case of wind down. Should not be called otherwise
    function buyBorrowToken() external onlyEmergencyAuthorized {
        _buyBorrowToken();
    }

    // ===============================================================
    // Keeper functions
    // ===============================================================

    /// @notice Auction off extra borrow token to asset
    /// @dev Should be called after a redemption/liquidation and when there's enough extra borrow token
    function kickRewards() external onlyKeepers {
        uint256 _have = balanceOfLentAssets() + balanceOfBorrowToken();
        uint256 _owe = balanceOfDebt();
        require(_have > _owe + DUST_THRESHOLD, "!rewards");
        uint256 _extra = _have - _owe;
        _withdrawFromLender(_extra);
        _sellBorrowToken(Math.min(_extra, balanceOfBorrowToken()));
    }

    // ===============================================================
    // Internal write functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _deployFunds(uint256 _amount) internal override {
        if (_amount > DUST_THRESHOLD) _leveragePosition(_amount);
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
        if (_amount > 0) _withdrawBorrowToken(Math.min(_amount, _lenderMaxWithdraw()));

        // last one turn off the lights
        BORROWER_OPERATIONS.closeTrove(troveId);

        uint256 _balance = WETH.balanceOf(address(this));
        if (_balance > 0) WETH.safeTransfer(msg.sender, _balance);
    }

    // ===============================================================
    // Internal view functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _getPrice(address _asset) internal view override returns (uint256 price) {
        AssetInfo memory _info = assetInfo[_asset];
        require(address(_info.priceFeed) != address(0), "!_priceFeed");
        (, int256 _answer,, uint256 _updatedAt,) = _info.priceFeed.latestRoundData();
        require(_answer > 0 && _updatedAt > block.timestamp - _info.heartbeat, "stale");
        uint256 _decimals = _info.priceFeed.decimals();
        return _decimals < PRICE_FEED_DECIMALS ? uint256(_answer) * (WAD / 10 ** _decimals) : uint256(_answer);
    }

    /// @inheritdoc BaseLenderBorrower
    function _isSupplyPaused() internal view override returns (bool) {
        return false;
    }

    /// @inheritdoc BaseLenderBorrower
    function _isBorrowPaused() internal view override returns (bool) {
        return false;
    }

    /// @inheritdoc BaseLenderBorrower
    function _isLiquidatable() internal view override returns (bool) {
        return TROVE_MANAGER.getCurrentICR(troveId, _getPrice(address(asset))) < BORROWER_OPERATIONS.MCR();
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
    function getNetBorrowApr(uint256 /* newAmount */ ) public view override returns (uint256) {
        return TROVE_MANAGER.getLatestTroveData(troveId).annualInterestRate;
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(uint256 /* newAmount */ ) public view override returns (uint256) {
        return WAD; // Assuming reward APR will never be less than borrowing APR (0.5%)
    }

    /// @inheritdoc BaseLenderBorrower
    function getLiquidateCollateralFactor() public view override returns (uint256) {
        return WAD * WAD / BORROWER_OPERATIONS.MCR();
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfCollateral() public view override returns (uint256) {
        return TROVE_MANAGER.getLatestTroveData(troveId).entireColl;
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfDebt() public view override returns (uint256) {
        return TROVE_MANAGER.getLatestTroveData(troveId).entireDebt;
    }

    // ===============================================================
    // Harvest / Token conversions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _claimRewards() internal override {
        return; // No rewards to claim
    }

    /// @inheritdoc BaseLenderBorrower
    function _claimAndSellRewards() internal override {
        return; // Use `kickRewards()` instead
    }

    /// @inheritdoc BaseLenderBorrower
    function _buyBorrowToken() internal override {
        uint256 _borrowTokenStillOwed = borrowTokenOwedBalance();
        if (_borrowTokenStillOwed > 0) {
            uint256 _maxAssetBalance = _fromUsd(_toUsd(_borrowTokenStillOwed, borrowToken), address(asset));
            if (_maxAssetBalance <= DUST_THRESHOLD) return;
            asset.safeTransfer(address(ASSET_TO_BORROW_AUCTION), _maxAssetBalance);
            ASSET_TO_BORROW_AUCTION.kick(address(asset));
        }
    }

    /// @inheritdoc BaseLenderBorrower
    function _sellBorrowToken(uint256 _amount) internal override {
        ERC20(borrowToken).safeTransfer(address(BORROW_TO_ASSET_AUCTION), _amount);
        BORROW_TO_ASSET_AUCTION.kick(borrowToken);
    }
}
