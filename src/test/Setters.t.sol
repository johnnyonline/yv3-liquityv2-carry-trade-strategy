// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";

contract SettersTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_unblockWithdrawalsAfterLiquidation() public {
        vm.expectRevert("!management");
        strategy.unblockWithdrawalsAfterLiquidation();

        assertTrue(strategy.blockWithdrawalsAfterLiquidation());
        vm.prank(management);
        strategy.unblockWithdrawalsAfterLiquidation();
        assertFalse(strategy.blockWithdrawalsAfterLiquidation());
    }

    function test_setMinKickAmount(uint256 _minKickAmount) public {
        vm.assume(_minKickAmount >= 1e14);

        vm.expectRevert("!management");
        strategy.setMinKickAmount(_minKickAmount);

        assertEq(strategy.minKickAmount(), MIN_KICK_AMOUNT);
        vm.prank(management);
        strategy.setMinKickAmount(_minKickAmount);
        assertEq(strategy.minKickAmount(), _minKickAmount);
    }

    function test_setMinKickAmount_invalidMinKickAmount(uint256 _invalidMinKickAmount) public {
        vm.assume(_invalidMinKickAmount < MIN_KICK_AMOUNT);

        vm.expectRevert("!kick");
        vm.prank(management);
        strategy.setMinKickAmount(_invalidMinKickAmount);
    }

    function test_setAuctionBufferPercentage(uint256 _auctionBufferPercentage) public {
        vm.assume(_auctionBufferPercentage >= MIN_AUCTION_BUFFER_PERCENTAGE);

        vm.expectRevert("!management");
        strategy.setAuctionBufferPercentage(_auctionBufferPercentage);

        assertEq(strategy.auctionBufferPercentage(), MIN_AUCTION_BUFFER_PERCENTAGE);
        vm.prank(management);
        strategy.setAuctionBufferPercentage(_auctionBufferPercentage);
        assertEq(strategy.auctionBufferPercentage(), _auctionBufferPercentage);
    }

    function test_setAuctionBufferPercentage_invalidAuctionBufferPercentage(uint256 _invalidAuctionBufferPercentage)
        public
    {
        vm.assume(_invalidAuctionBufferPercentage < MIN_AUCTION_BUFFER_PERCENTAGE);

        vm.expectRevert("!buffer");
        vm.prank(management);
        strategy.setAuctionBufferPercentage(_invalidAuctionBufferPercentage);
    }

    function test_openTrove() public {
        vm.expectRevert("!management");
        strategy.openTrove(0, 0);

        strategistDepositAndOpenTrove(true);
        assertTrue(strategy.troveId() > 0, "troveId");

        vm.expectRevert("troveId");
        vm.prank(management);
        strategy.openTrove(0, 0);
    }

    function test_claimCollateral_invalidCaller(address _invalidCaller) public {
        vm.assume(_invalidCaller != management);

        vm.expectRevert("!management");
        vm.prank(_invalidCaller);
        strategy.claimCollateral();
    }

    function test_buyBorrowToken_invalidCaller(address _invalidCaller) public {
        vm.assume(_invalidCaller != emergencyAdmin && _invalidCaller != management);

        vm.expectRevert("!emergency authorized");
        vm.prank(_invalidCaller);
        strategy.buyBorrowToken();
    }

    function test_kickRewards_invalidCaller(address _invalidCaller) public {
        vm.assume(_invalidCaller != keeper && _invalidCaller != management);

        vm.expectRevert("!keeper");
        vm.prank(_invalidCaller);
        strategy.kickRewards();
    }

    function test_kickRewards_noRewards() public {
        vm.expectRevert("!rewards");
        vm.prank(keeper);
        strategy.kickRewards();
    }

    function test_adjustZombieTrove_invalidCaller(address _invalidCaller) public {
        vm.assume(_invalidCaller != keeper);

        vm.expectRevert("!keeper");
        vm.prank(_invalidCaller);
        strategy.adjustZombieTrove(0, 0);
    }

    function test_setAssetInfo(uint256 _invalidHeartbeat) public {
        vm.assume(_invalidHeartbeat > 1 days);

        vm.expectRevert("heartbeat");
        vm.prank(management);
        priceProvider.setAssetInfo(_invalidHeartbeat, address(0), address(0));

        vm.expectRevert("Ownable: caller is not the owner");
        priceProvider.setAssetInfo(_invalidHeartbeat, address(0), address(0));

        skip(1 hours);
        vm.expectRevert("stale");
        vm.prank(management);
        priceProvider.setAssetInfo(1 hours, address(0), clEthUsdOracle);
    }
}
