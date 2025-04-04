// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {PriceProvider} from "../../PriceProvider.sol";
import {LiquityV2CarryTradeStrategy as Strategy, ERC20} from "../../Strategy.sol";
import {StrategyFactory} from "../../StrategyFactory.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {IHintHelpers} from "../../interfaces/IHintHelpers.sol";
import {ITroveManager} from "../../interfaces/ITroveManager.sol";
import {ISortedTroves} from "../../interfaces/ISortedTroves.sol";
import {IBorrowerOperations} from "../../interfaces/IBorrowerOperations.sol";
import {ICollateralRegistry} from "../../interfaces/ICollateralRegistry.sol";

import {SavingsBoldMock} from "../mocks/SavingsBoldMock.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is ExtendedTest, IEvents {

    // Fork contracts
    // liquity v2.1 WETH
    address public collateralRegistry = 0xd99dE73b95236F69A559117ECD6F519Af780F3f7;
    address public addressesRegistry = 0x38e1F07b954cFaB7239D7acab49997FBaAD96476;
    address public borrowerOperations = 0x0B995602B5a797823f92027E8b40c0F2D97Aff1C;
    address public troveManager = 0x81D78814DF42DA2caB0E8870C477bC3Ed861DE66;
    address public hintHelpers = 0xe3BB97EE79aC4BdFc0c30A95aD82c243c9913aDa;
    address public sortedTroves = 0x879474Cfbb980fB6899aaaA9b5D5EE14fFbF85A9;
    uint256 public branchIndex = 0;
    //
    address public clEthUsdOracle = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public clUsdcUsdOracle = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    // uint256 public clEthUsdOracleHeartbeat = 1 hours;
    // uint256 public clUsdcUsdOracleHeartbeat = 24 hours;
    uint256 public clEthUsdOracleHeartbeat = 100 days;
    uint256 public clUsdcUsdOracleHeartbeat = 100 days;

    // Contract instances that we will use repeatedly.
    ERC20 public borrowToken;
    ERC20 public asset;
    IStrategy public lenderVault;
    IStrategyInterface public strategy;
    PriceProvider public priceProvider;

    StrategyFactory public strategyFactory;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public strategist = address(69);
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1m of a 1e18 coin
    uint256 public maxFuzzAmount = 1_000_000 * 1e18;
    uint256 public minFuzzAmount = 10_000;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    // Amount strategist deposits after deployment to open a trove
    uint256 public initialStrategistDeposit = 2 ether;

    // Constants from the Strategy
    uint256 public constant ETH_GAS_COMPENSATION = 0.0375 ether;
    uint256 private constant MIN_ANNUAL_INTEREST_RATE = 1e18 / 100 / 2; // 0.5%
    uint256 private constant MIN_DEBT = 2_000 * 1e18;

    function setUp() public virtual {
        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["WETH"]);

        // Set borrowToken
        borrowToken = ERC20(tokenAddrs["BOLD"]);

        // Set mock
        lenderVault = IStrategy(address(new SavingsBoldMock(address(borrowToken), address(asset))));

        // Set decimals
        decimals = asset.decimals();

        strategyFactory = new StrategyFactory(management, performanceFeeRecipient, keeper, emergencyAdmin);

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        _lowerTCR(); // add lots of collateral and borrow almost nothing to lower the Trove Collateral Ratio

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        priceProvider = new PriceProvider();

        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                strategyFactory.newStrategy(
                    address(asset),
                    "Tokenized Strategy",
                    address(borrowToken),
                    address(lenderVault),
                    address(addressesRegistry),
                    address(priceProvider) // priceProvider
                )
            )
        );

        vm.prank(management);
        _strategy.acceptManagement();

        priceProvider.transferOwnership(management);
        vm.prank(management);
        priceProvider.acceptOwnership();

        setUpPriceProvider();

        return address(_strategy);
    }

    function strategistDepositAndOpenTrove() public returns (uint256) {
        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, strategist, initialStrategistDeposit);

        // Approve gas compensation spending
        airdrop(ERC20(tokenAddrs["WETH"]), strategist, ETH_GAS_COMPENSATION);
        vm.prank(strategist);
        ERC20(tokenAddrs["WETH"]).approve(address(strategy), ETH_GAS_COMPENSATION);

        // Open Trove
        (uint256 _upperHint, uint256 _lowerHint) = findHints();
        vm.prank(management);
        strategy.openTrove(_upperHint, _lowerHint, strategist);

        return initialStrategistDeposit;
    }

    function depositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function mockLenderEarnInterest(uint256 _amountDeposited) public {
        uint256 _amountInUsd = _amountDeposited * priceProvider.getPrice(address(asset)) / 1e18;
        uint256 _interestAmount = _amountInUsd * 1 / 100; // 1% interest
        uint256 _totalAssetsBefore = lenderVault.totalAssets();
        airdrop(borrowToken, address(lenderVault), _interestAmount);
        require(lenderVault.totalAssets() > _totalAssetsBefore, "No interest earned");
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function setUpPriceProvider() public {
        vm.startPrank(management);
        priceProvider.setAssetInfo(clEthUsdOracleHeartbeat, address(asset), clEthUsdOracle);
        priceProvider.setAssetInfo(clUsdcUsdOracleHeartbeat, address(borrowToken), clUsdcUsdOracle);
        vm.stopPrank();
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        tokenAddrs["BOLD"] = 0xb01dd87B29d187F3E3a4Bf6cdAebfb97F3D9aB98;
    }

    function findHints() internal view returns (uint256 _upperHint, uint256 _lowerHint) {
        // Find approx hint (off-chain)
        (uint256 _approxHint,,) = IHintHelpers(hintHelpers).getApproxHint({
            _collIndex: branchIndex,
            _interestRate: MIN_ANNUAL_INTEREST_RATE,
            _numTrials: sqrt(100 * ITroveManager(troveManager).getTroveIdsCount()),
            _inputRandomSeed: block.timestamp
        });

        // Find concrete insert position (off-chain)
        (_upperHint, _lowerHint) = ISortedTroves(sortedTroves).findInsertPosition(MIN_ANNUAL_INTEREST_RATE, _approxHint, _approxHint);
    }

    function sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _lowerTCR() private {
        address sugardaddy = address(42069);
        uint256 reallyreallybigamount = 1_000_000 ether;
        airdrop(asset, sugardaddy, reallyreallybigamount);
        uint256 collAmount = asset.balanceOf(sugardaddy);
        airdrop(ERC20(tokenAddrs["WETH"]), sugardaddy, ETH_GAS_COMPENSATION);
        (uint256 upperHint, uint256 lowerHint) = findHints();
        vm.startPrank(sugardaddy);
        ERC20(tokenAddrs["WETH"]).approve(borrowerOperations, type(uint256).max);
        asset.approve(borrowerOperations, type(uint256).max);
        IBorrowerOperations(borrowerOperations).openTrove(
            sugardaddy, // owner
            0, // ownerIndex
            collAmount,
            MIN_DEBT, // boldAmount
            upperHint,
            lowerHint,
            MIN_ANNUAL_INTEREST_RATE, // annualInterestRate
            type(uint256).max, // maxUpfrontFee
            address(0), // addManager
            address(0), // removeManager
            address(0) // receiver
        );
        vm.stopPrank();
    }

    function simulateCollateralRedemption(uint256 _amount) internal {
        address _redeemer = address(420420);
        airdrop(borrowToken, _redeemer, _amount);
        vm.prank(_redeemer);
        ICollateralRegistry(collateralRegistry).redeemCollateral(
            _amount,
            0, // max iterations
            1_000_000_000_000_000_000 // max fee percentage
        );
        require(
            uint8(ITroveManager(troveManager).getTroveStatus(strategy.troveId())) == uint8(ITroveManager.Status.zombie),
            "Trove not active420"
        );
    }
}
