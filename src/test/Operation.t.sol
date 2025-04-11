// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {
    error NotEnoughBoldBalance();

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        assertTrue(strategy.blockWithdrawalsAfterLiquidation(), "!blockWithdrawalsAfterLiquidation");
        assertEq(strategy.troveId(), 0, "!troveId");
        assertEq(strategy.auctionBufferPercentage(), MIN_AUCTION_BUFFER_PERCENTAGE, "!auctionBufferPercentage");
        assertEq(strategy.minKickAmount(), MIN_KICK_AMOUNT, "!minKickAmount");
        assertTrue(strategy.ASSET_TO_BORROW_AUCTION() != address(0), "!ASSET_TO_BORROW_AUCTION");
        assertTrue(strategy.BORROW_TO_ASSET_AUCTION() != address(0), "!BORROW_TO_ASSET_AUCTION");
        assertEq(strategy.PRICE_PROVIDER(), address(priceProvider), "!priceProvider");
        assertEq(strategy.BORROWER_OPERATIONS(), address(borrowerOperations), "!borrowerOperations");
        assertEq(strategy.TROVE_MANAGER(), address(troveManager), "!troveManager");
        assertTrue(strategy.leaveDebtBehind(), "!leaveDebtBehind");
    }

    function test_setupStrategyOK_afterOpenTrove(uint256 _delta) public {
        strategistDepositAndOpenTrove(true);

        assertTrue(strategy.troveId() != 0, "!troveId");
        assertEq(ERC20(tokenAddrs["WETH"]).balanceOf(address(strategy)), 0, "!wethBalance");
        assertEq(strategy.getNetBorrowApr(_delta), MIN_ANNUAL_INTEREST_RATE, "!getNetBorrowApr");
        assertGt(strategy.getNetRewardApr(_delta), strategy.getNetBorrowApr(_delta), "!getNetRewardApr");
        assertEq(strategy.getLiquidateCollateralFactor(), liquidateCollateralFactor, "!getLiquidateCollateralFactor");
        assertApproxEq(strategy.balanceOfDebt(), MIN_DEBT, 1e18, "!balanceOfDebt");
    }

    function test_invalidDeployment() public {
        vm.expectRevert("!lenderVault");
        strategyFactory.newStrategy(
            tokenAddrs["LINK"],
            "Tokenized Strategy",
            address(borrowToken),
            address(lenderVault),
            address(addressesRegistry),
            address(priceProvider)
        );

        vm.expectRevert("!lenderVault");
        strategyFactory.newStrategy(
            address(asset),
            "Tokenized Strategy",
            address(0),
            address(lenderVault),
            address(addressesRegistry),
            address(priceProvider)
        );

        vm.expectRevert("!addressesRegistry");
        strategyFactory.newStrategy(
            address(asset),
            "Tokenized Strategy",
            address(borrowToken),
            address(lenderVault),
            address(0x3b48169809DD827F22C9e0F2d71ff12Ea7A94a2F), // rETH addressesRegistry
            address(priceProvider)
        );

        vm.expectRevert("!priceProvider");
        strategyFactory.newStrategy(
            address(asset),
            "Tokenized Strategy",
            address(borrowToken),
            address(lenderVault),
            address(addressesRegistry),
            address(0)
        );
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        // Earn Interest
        mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        balanceBefore = asset.balanceOf(strategist);

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        assertGe(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
    }

    function test_operation_lostLentAssets(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        uint256 vaultLoss = lenderVault.totalAssets() * 5 / 100; // 5% loss
        vm.prank(address(lenderVault));
        ERC20(borrowToken).transfer(management, vaultLoss);

        // Revert on health check
        vm.prank(keeper);
        vm.expectRevert("healthCheck");
        strategy.report();

        // Set health check to accept loss
        vm.prank(management);
        strategy.setLossLimitRatio(5_000); // 50% loss

        // Report loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertGe(loss, 0, "!loss");

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.expectRevert(NotEnoughBoldBalance.selector); // Not enough BOLD to repay the loan
        strategy.emergencyWithdraw(type(uint256).max);

        // Withdraw enough collateral to repay the loan
        uint256 collToSell = strategy.balanceOfCollateral() * 25 / 100;
        strategy.manualWithdraw(address(0), collToSell);

        // Sell collateral to buy debt
        strategy.buyBorrowToken();

        // Buying just enough to repay the loan
        uint256 toAuction = asset.balanceOf(strategy.ASSET_TO_BORROW_AUCTION());
        assertLe(toAuction, collToSell, "!collToSell");
        uint256 toAirdrop = toAuction * priceProvider.getPrice(address(asset)) / 1e18;
        airdrop(borrowToken, address(strategy), toAirdrop);

        // Close trove and repay the loan
        strategy.emergencyWithdraw(type(uint256).max);

        // Sell any leftover borrow token to asset
        strategy.sellBorrowToken(type(uint256).max);
        toAuction = borrowToken.balanceOf(strategy.BORROW_TO_ASSET_AUCTION());
        assertGt(toAuction, 0, "!borrowToSell");
        toAirdrop = toAuction * priceProvider.getPrice(address(borrowToken)) / 1e18;
        airdrop(asset, address(strategy), toAirdrop);

        vm.stopPrank();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertLt(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // 5% loss max
        assertApproxEq(asset.balanceOf(user), balanceBefore + _amount, balanceBefore + _amount * 5 / 100);

        vm.prank(strategist);
        strategy.redeem(strategistDeposit - 1, strategist, strategist);

        assertLt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");

        // 5% loss max, same as user
        assertApproxEq(
            asset.balanceOf(strategist), balanceBefore + strategistDeposit, balanceBefore + strategistDeposit * 5 / 100
        );
    }

    function test_partialWithdrawLowersLTV(uint256 _amount) public {
        vm.assume(_amount > 1 ether && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        // Earn Interest
        mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        // lower LTV
        uint256 borrowed = strategy.balanceOfDebt();
        airdrop(ERC20(borrowToken), address(strategy), borrowed / 4);

        vm.prank(management);
        strategy.manualRepayDebt();

        assertLt(strategy.getCurrentLTV(), targetLTV);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount / 2, user, user, 1);

        assertGe(asset.balanceOf(user), ((balanceBefore + (_amount / 2)) * 9_999) / MAX_BPS, "!final balance");
    }

    function test_profitableReport(uint256 _amount) public {
        vm.assume(_amount > 1 ether && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        // Earn Interest
        mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        // Sell interest
        vm.prank(keeper);
        strategy.kickRewards();
        uint256 toAuction = borrowToken.balanceOf(strategy.BORROW_TO_ASSET_AUCTION());
        assertGt(toAuction, 0, "!borrowToSell");
        uint256 toAirdrop = toAuction * 1e18 / priceProvider.getPrice(address(asset));
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertGt(strategy.totalAssets(), _amount + strategistDeposit);

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(1 hours); // not waiting for full unlock bc of oracles
        freezeOracles();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGt(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        // Earn Interest again (this time not selling rewards)
        mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        balanceBefore = asset.balanceOf(strategist);

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist);

        assertGt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
    }

    function test_profitableReport_withFees(uint256 _amount, uint16 _profitFactor) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");

        uint256 toAirdrop = ((_amount + strategistDeposit) * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(1 hours); // not waiting for full unlock bc of oracles
        freezeOracles();

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        vm.prank(performanceFeeRecipient);
        strategy.redeem(expectedShares, performanceFeeRecipient, performanceFeeRecipient);

        assertGe(asset.balanceOf(performanceFeeRecipient), expectedShares, "!perf fee out");

        // Earn Interest
        mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        balanceBefore = asset.balanceOf(strategist);

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist);

        assertGt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > 1 ether && _amount < maxFuzzAmount); // increase min fuzz bc of minDebt requirement

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // No assets should be false.
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Withdrawl some collateral to pump LTV
        uint256 collToSell = strategy.balanceOfCollateral() * 20 / 100;
        vm.prank(emergencyAdmin);
        strategy.manualWithdraw(address(0), collToSell);

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "warning ltv");

        // Even with a 0 for max Tend Base Fee its true
        vm.prank(management);
        strategy.setMaxGasPriceToTend(0);

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "warning ltv 2");

        // Get max gas price back to normal
        vm.prank(management);
        strategy.setMaxGasPriceToTend(200e9);

        vm.prank(keeper);
        strategy.tend();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger, "post tend");

        // Earn Interest
        mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        vm.prank(keeper);
        strategy.report();

        // Lower LTV
        uint256 borrowed = strategy.balanceOfDebt();
        airdrop(ERC20(borrowToken), address(strategy), borrowed / 2);

        vm.prank(management);
        strategy.manualRepayDebt();

        assertLt(strategy.getCurrentLTV(), targetLTV);

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function test_operation_overWarningLTV_depositLeversDown(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        // Withdrawl some collateral to pump LTV
        uint256 collToSell = strategy.balanceOfCollateral() * 20 / 100;
        vm.prank(emergencyAdmin);
        strategy.manualWithdraw(address(0), collToSell);

        uint256 warningLTV = (strategy.getLiquidateCollateralFactor() * strategy.warningLTVMultiplier()) / MAX_BPS;

        assertGt(strategy.getCurrentLTV(), warningLTV);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
    }

    function test_operation_redemptionToZombie(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        uint256 debtBefore = strategy.balanceOfDebt();

        // Simulate a redemption that leads to a zombie trove
        simulateCollateralRedemption(strategy.balanceOfDebt() * 10, true); // not super tight... but gets the job done for now

        // Check debt decreased
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");

        // Kick rewards to get rid of borrow token back to asset
        vm.prank(keeper);
        strategy.kickRewards();
        uint256 toAuction = borrowToken.balanceOf(strategy.BORROW_TO_ASSET_AUCTION());
        assertGt(toAuction, 0, "!borrowToSell");
        uint256 toAirdrop = toAuction * 1e18 / priceProvider.getPrice(address(asset));
        airdrop(asset, address(strategy), toAirdrop);

        // Position zombie should be false
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "zombieTrigger");

        // Report profit (doesn't leverage)
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit"); // If no price swinges / other costs, being redeemed is actually profitable
        assertEq(loss, 0, "!loss");
        assertLt(strategy.getCurrentLTV(), targetLTV, "!ltv");

        // AdjustZombieTrove
        (uint256 _upperHint, uint256 _lowerHint) = findHints();
        vm.expectRevert("!keeper");
        strategy.adjustZombieTrove(_upperHint, _lowerHint);
        vm.prank(keeper);
        strategy.adjustZombieTrove(_upperHint, _lowerHint);

        uint256 balanceBefore = asset.balanceOf(user);

        // User withdraw all funds before report
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        balanceBefore = asset.balanceOf(strategist);

        // Earn Interest
        mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        // Report profit
        vm.prank(keeper);
        (profit, loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        assertGe(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
    }

    function test_operation_redemptionNoZombie(uint256 _amount) public {
        minFuzzAmount = 10 ether; // making sure we take a large enough loan so we don't end up with a zombie trove
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        uint256 debtBefore = strategy.balanceOfDebt();

        // Simulate a redemption that doesnt lead to a zombie trove
        simulateCollateralRedemption(strategy.balanceOfDebt(), false);

        // Check debt decreased
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");

        // Kick rewards to get rid of borrow token back to asset
        vm.prank(keeper);
        strategy.kickRewards();
        uint256 toAuction = borrowToken.balanceOf(strategy.BORROW_TO_ASSET_AUCTION());
        assertGt(toAuction, 0, "!borrowToSell");
        uint256 toAirdrop = toAuction * 1e18 / priceProvider.getPrice(address(asset));
        airdrop(asset, address(strategy), toAirdrop);

        // Position not zombie should be true
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "!zombieTrigger");

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        uint256 balanceBefore = asset.balanceOf(user);

        // User withdraw all funds before report
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        balanceBefore = asset.balanceOf(strategist);

        // Earn Interest
        mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        // Report profit
        vm.prank(keeper);
        (profit, loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        assertGe(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
    }

    function test_operation_redemptionToZombie_withLoss(uint256 _amount) public {
        maxFuzzAmount = 10 ether; // making sure our loan's not too big so the redemption doesn't lead profits
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        initialStrategistDeposit = 10 ether; // bigger deposit to user can withdraw without touching collateral
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        uint256 debtBefore = strategy.balanceOfDebt();

        // Simulate a redemption that leads to a zombie trove
        simulateCollateralRedemption(strategy.balanceOfDebt() * 10, true);

        // Check debt decreased
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");

        // Kick rewards to get rid of borrow token back to asset
        vm.prank(keeper);
        strategy.kickRewards();
        uint256 toAuction = borrowToken.balanceOf(strategy.BORROW_TO_ASSET_AUCTION());
        assertGt(toAuction, 0, "!borrowToSell");
        uint256 toAirdrop = toAuction * 1e18 / priceProvider.getPrice(address(asset));
        airdrop(asset, address(strategy), toAirdrop * 80 / 100); // 20% loss

        // Position zombie should be false
        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "zombieTrigger");

        // User can withdraw before loss is reported
        uint256 balanceBefore = asset.balanceOf(user);

        // User withdraw all funds before report without taking a loss
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // Set health check to accept loss
        vm.prank(management);
        strategy.setLossLimitRatio(5_000); // 50% loss

        // Report loss (doesn't leverage)
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");
        assertLt(strategy.getCurrentLTV(), targetLTV, "!ltv");

        // AdjustZombieTrove
        (uint256 _upperHint, uint256 _lowerHint) = findHints();
        vm.prank(keeper);
        strategy.adjustZombieTrove(_upperHint, _lowerHint);

        balanceBefore = asset.balanceOf(strategist);

        // Earn Interest
        mockLenderEarnInterest(strategistDeposit); // 1% interest

        // Report profit
        vm.prank(keeper);
        (profit, loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        // Make sure strategist lost max 20%
        assertGt(asset.balanceOf(strategist), balanceBefore + (strategistDeposit * 80) / 100, "!lossAmount");
        assertLt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
    }

    function test_operation_redemptionNoZombie_withLoss(uint256 _amount) public {
        vm.assume(_amount > 2 ether && _amount < 10 ether); // Need to keep the right balance here

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        uint256 debtBefore = strategy.balanceOfDebt();

        // Simulate a redemption that doesnt lead to a zombie trove
        simulateCollateralRedemption(strategy.balanceOfDebt(), false);

        // Check debt decreased
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");

        // Kick rewards to get rid of borrow token back to asset
        vm.prank(keeper);
        strategy.kickRewards();
        uint256 toAuction = borrowToken.balanceOf(strategy.BORROW_TO_ASSET_AUCTION());
        assertGt(toAuction, 0, "!borrowToSell");
        uint256 toAirdrop = toAuction * 1e18 / priceProvider.getPrice(address(asset));
        airdrop(asset, address(strategy), toAirdrop * 80 / 100); // 20% loss

        // Position not zombie should be true
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "!zombieTrigger");

        // User can withdraw before loss is reported
        uint256 balanceBefore = asset.balanceOf(user);

        // User withdraw all funds before report without taking a loss
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertLe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // Set health check to accept loss
        vm.prank(management);
        strategy.setLossLimitRatio(5_000); // 50% loss

        // Report loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);

        balanceBefore = asset.balanceOf(strategist);

        // Earn Interest
        mockLenderEarnInterest(strategistDeposit); // 1% interest

        // Report profit
        vm.prank(keeper);
        (profit, loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist);

        // Make sure strategist lost max 20%
        assertGt(asset.balanceOf(strategist), balanceBefore + (strategistDeposit * 80) / 100, "!lossAmount");
        assertLt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!strategist final balance");
    }

    function test_operation_liquidation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertRelApproxEq(strategy.getCurrentLTV(), targetLTV, 1000);
        assertApproxEq(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertRelApproxEq(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1000);

        (bool trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "!liq");

        // Simulate a liquidation
        simulateLiquidation();

        // Check debt
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(strategy.balanceOfCollateral(), 0, "!collateral");
        assertEq(strategy.balanceOfAsset(), 0, "!asset");
        assertGt(strategy.balanceOfLentAssets(), 0, "!lentAssets");

        // Kick rewards to get rid of borrow token back to asset
        vm.prank(keeper);
        strategy.kickRewards();
        uint256 toAuction = borrowToken.balanceOf(strategy.BORROW_TO_ASSET_AUCTION());
        assertGt(toAuction, 0, "!borrowToSell");
        uint256 toAirdrop = toAuction * 1e18 / priceProvider.getPrice(address(asset));
        airdrop(asset, address(strategy), toAirdrop);

        // Check we revert on report (will revert until we re-open trove)
        vm.prank(keeper);
        vm.expectRevert();
        strategy.report();

        // Check we can't withdraw
        vm.prank(user);
        vm.expectRevert("ERC4626: redeem more than max"); // blocked by `availableWithdrawLimit()`
        strategy.redeem(_amount, user, user);

        // Claim any leftover collateral
        vm.prank(management);
        vm.expectRevert("CollSurplusPool: No collateral available to claim"); // dumped too hard
        strategy.claimCollateral();

        // Make sure can't open a new trove
        vm.prank(management);
        vm.expectRevert("troveId");
        strategy.openTrove(0, 0);

        // Allow for loss
        vm.prank(management);
        strategy.setLossLimitRatio(5_000); // 50% loss

        // Report loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss"); // Lost bc of liquidation penalty
        assertLt(loss, (_amount + strategistDeposit) * 10 / 100, "loss too high"); // make sure loss is not more than 10%

        // Shutdown the strategy
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Unblock withdrawals
        vm.prank(management);
        strategy.unblockWithdrawalsAfterLiquidation();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Make sure user lost max 10%
        assertGt(asset.balanceOf(user), balanceBefore + (_amount * 90) / 100, "!final balance");

        balanceBefore = asset.balanceOf(strategist);

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        // Make sure strategist lost max 10%
        assertGt(asset.balanceOf(strategist), balanceBefore + (strategistDeposit * 90) / 100, "!final balance");
    }
}
