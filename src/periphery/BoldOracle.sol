// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {ICurveStablePool} from "../interfaces/ICurveStablePool.sol";

contract BoldOracle is IPriceFeed {
    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice The decimals difference between the Curve pool and the price feed
    uint256 private constant CL_DECIMALS_DIFF = 1e28;

    /// @notice The heartbeat for the USDC/USD price feed
    uint256 private constant USDC_USD_CL_HEARTBEAT = 24 hours;

    /// @notice The BOLD/USDC Curve pool
    ICurveStablePool public constant CURVE_POOL = ICurveStablePool(0xaDb6851875B7496E3D565B754d8a79508480a203);

    /// @notice The USDC/USD Chainlink price feed
    IPriceFeed public constant USDC_USD_CL_PRICE_FEED = IPriceFeed(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Making sure the USDC/USD price feed has the expected decimals
    constructor() {
        // assuming this will always be true
        require(USDC_USD_CL_PRICE_FEED.decimals() == 8);
    }

    // ============================================================================================
    // View functions
    // ============================================================================================

    /// @notice Returns the number of decimals used by the price feed
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Returns the version of the price feed
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @notice Returns the description of the price feed
    function description() external pure returns (string memory) {
        return "BOLD/USD Price Feed";
    }

    /// @notice Returns the latest price of the asset in USD
    /// @return The price of the asset in USD
    function latestAnswer() external view returns (int256) {
        return _getPrice();
    }

    /// @notice Returns the latest round data from the price feed
    /// @return The round ID
    /// @return The price of the asset in USD
    /// @return The timestamp of the start of the round
    /// @return The timestamp of the last update
    /// @return The round ID in which the price was answered
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (int256 _price, uint256 _updatedAt) = _getPriceWithTimestamp();
        return (0, _price, 0, _updatedAt, 0);
    }

    // ============================================================================================
    // Internal functions
    // ============================================================================================

    function _getPrice() internal view returns (int256) {
        (uint256 _usdcPrice,) = _getUsdcPrice();
        return _calcPrice(_usdcPrice);
    }

    function _getPriceWithTimestamp() internal view returns (int256, uint256) {
        (uint256 _usdcPrice, uint256 _updatedAt) = _getUsdcPrice();
        return (_calcPrice(_usdcPrice), _updatedAt);
    }

    function _calcPrice(uint256 _usdcPrice) internal view returns (int256) {
        return int256(_usdcPrice * CL_DECIMALS_DIFF / CURVE_POOL.price_oracle(0));
    }

    function _getUsdcPrice() internal view returns (uint256, uint256) {
        (, int256 _price,, uint256 _updatedAt,) = USDC_USD_CL_PRICE_FEED.latestRoundData();
        require(_updatedAt + USDC_USD_CL_HEARTBEAT > block.timestamp, "stale");
        require(_price > 0, "!price");
        return (uint256(_price), _updatedAt);
    }
}
