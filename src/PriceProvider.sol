// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract PriceProvider is Ownable2Step {

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

    /// @notice Asset info
    mapping(address asset => AssetInfo info) public assetInfo;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice WAD constant
    uint256 private constant WAD = 1e18;

    /// @notice `_getPrice` returns the price of the asset with 18 decimals
    uint256 public constant PRICE_FEED_DECIMALS = 18;

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @notice Constructor
    constructor() Ownable2Step() {}

    // ===============================================================
    // Owner functions
    // ===============================================================

    /// @notice Set asset info
    /// @param _heartbeat Heartbeat
    /// @param _asset Asset address
    /// @param _priceFeed Price feed
    function setAssetInfo(uint256 _heartbeat, address _asset, address _priceFeed) external onlyOwner {
        require(_heartbeat <= 1 days, "heartbeat");
        (, int256 _answer,, uint256 _updatedAt,) = IPriceFeed(_priceFeed).latestRoundData();
        require(_answer > 0 && _updatedAt > block.timestamp - _heartbeat, "stale");
        assetInfo[_asset] = AssetInfo(_heartbeat, IPriceFeed(_priceFeed));
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Get price
    /// @param _asset Asset address
    /// @return Price
    function getPrice(address _asset) external view returns (uint256) {
        AssetInfo memory _info = assetInfo[_asset];
        require(address(_info.priceFeed) != address(0), "!_priceFeed");
        (, int256 _answer,, uint256 _updatedAt,) = _info.priceFeed.latestRoundData();
        require(_answer > 0 && _updatedAt > block.timestamp - _info.heartbeat, "stale");
        uint256 _decimals = _info.priceFeed.decimals();
        return _decimals < PRICE_FEED_DECIMALS ? uint256(_answer) * (WAD / 10 ** _decimals) : uint256(_answer);
    }
}