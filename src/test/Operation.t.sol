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
        mockLenderEarnInterest(_amount + strategistDeposit);

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
        vm.assume(_amount > 0.1 ether && _amount < maxFuzzAmount);

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
        assertRelApproxEq(asset.balanceOf(user), balanceBefore + _amount, 2e17); // 10% loss max // @todo -- here

        vm.prank(strategist);
        strategy.redeem(strategistDeposit - 1, strategist, strategist);

        assertLt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
    }

    function test_profitableReport(uint256 _amount, uint16 _profitFactor) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport_withFees(uint256 _amount, uint16 _profitFactor) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

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

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(asset.balanceOf(performanceFeeRecipient), expectedShares, "!perf fee out");
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}
