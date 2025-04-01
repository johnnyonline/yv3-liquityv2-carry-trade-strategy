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
        // TODO: add additional check on strat params
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove();

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
        uint256 strategistDeposit = strategistDepositAndOpenTrove();

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

        strategy.emergencyWithdraw(type(uint256).max);

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

        assertLt(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        // 5% loss max
        assertApproxEq(asset.balanceOf(user), balanceBefore + _amount, balanceBefore + _amount * 5 / 100);

        vm.prank(strategist);
        strategy.redeem(strategistDeposit - 1, strategist, strategist);

        assertLt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");

        // 5% loss max, same as user
        assertApproxEq(asset.balanceOf(strategist), balanceBefore + strategistDeposit, balanceBefore + strategistDeposit * 5 / 100);
    }

    function test_partialWithdraw_lowerLTV(uint256 _amount) public {
        vm.assume(_amount > 1 ether && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove();

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

        assertGe(
            asset.balanceOf(user),
            ((balanceBefore + (_amount / 2)) * 9_999) / MAX_BPS,
            "!final balance"
        );
    }

    function test_profitableReport(uint256 _amount) public {
        vm.assume(_amount > 1 ether && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove();

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);

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

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGt(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

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
        uint256 strategistDeposit = strategistDepositAndOpenTrove();

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
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove();

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Withdrawl some collateral to pump LTV
        uint256 collToSell = strategy.balanceOfCollateral() * 20 / 100;
        vm.prank(emergencyAdmin);
        strategy.manualWithdraw(address(0), collToSell);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "warning ltv");

        // Even with a 0 for max Tend Base Fee its true
        vm.prank(management);
        strategy.setMaxGasPriceToTend(0);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "warning ltv 2");

        // Even with a 0 for max Tend Base Fee its true
        vm.prank(management);
        strategy.setMaxGasPriceToTend(200e9);

        vm.prank(keeper);
        strategy.tend();

        (trigger, ) = strategy.tendTrigger();
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

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function test_operation_overWarningLTV_depositLeversDown(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove();

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
        uint256 strategistDeposit = strategistDepositAndOpenTrove();

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
        simulateCollateralRedemption(strategy.balanceOfDebt() * 10); // not super tight... but gets the job done for now

        // Check debt decreased
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");

        // @todo -- here
        // 3. Kick rewards to get rid of borrow token back to asset
        // 4. Check we revert on withdraw/report/tend
        // 5. Check we dont revert on deposit
        // 6. adjustZombieTrove
        // 7. Report profit?
        // Close trove

        // // Earn Interest
        // mockLenderEarnInterest(_amount + strategistDeposit); // 1% interest

        // // Report profit
        // vm.prank(keeper);
        // (uint256 profit, uint256 loss) = strategy.report();

        // // Check return Values
        // assertGe(profit, 0, "!profit");
        // assertEq(loss, 0, "!loss");

        // uint256 balanceBefore = asset.balanceOf(user);

        // // Withdraw all funds
        // vm.prank(user);
        // strategy.redeem(_amount, user, user);

        // assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // balanceBefore = asset.balanceOf(strategist);

        // // Shutdown the strategy (can't repay entire debt without)
        // vm.startPrank(emergencyAdmin);
        // strategy.shutdownStrategy();
        // strategy.emergencyWithdraw(type(uint256).max);
        // vm.stopPrank();

        // // Strategist withdraws all funds
        // vm.prank(strategist);
        // strategy.redeem(strategistDeposit, strategist, strategist, 0);

        // assertGe(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
    }

    // @todo -- here -- test redemption/open trove after liquidation
}
