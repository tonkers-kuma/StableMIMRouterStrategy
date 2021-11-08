// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
SafeERC20,
SafeMath,
IERC20,
Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "./RouterStrategy.sol";
import "./AbracadabraBorrower.sol";

// TODO: Note: It seems like this contract isn't benefiting much from inheriting from RouterStrategy
// TODO: in fact, some accounting like delegatedAssets would be better off here where it has visibility to mimToCollat()
contract MIMMinterRouterStrategy is RouterStrategy, AbracadabraBorrower {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;


    constructor(
        address _vault,
        address _yVault,
        string memory _strategyName,
        address _abracadabra,
        uint256 _maxCollatRate,
        uint256 _targetCollatRate,
        bool _underlying_is_lp
    ) public RouterStrategy(_vault, _yVault, _strategyName) {
        _initializeMIMMinterRouter(_abracadabra, _maxCollatRate, _targetCollatRate, _underlying_is_lp);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yVault,
        address _abracadabra,
        uint256 _maxCollatRate,
        uint256 _targetCollatRate,
        bool _underlying_is_lp,
        string memory _strategyName
    ) public {
        super.initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _yVault,
            _strategyName
        );
        _initializeMIMMinterRouter(_abracadabra, _maxCollatRate, _targetCollatRate, _underlying_is_lp);
    }

    function _initializeMIMMinterRouter(address _abracadabra, uint256 _maxCollatRate, uint256 _targetCollatRate, bool _underlying_is_lp)
    internal
    {
        _initializeAbracadabraBorrower(_abracadabra, _maxCollatRate, _targetCollatRate, _underlying_is_lp);

        maxLoss = 1;
    }

    // TODO: Critical: Need to override tendTrigger to check for state of collateral.
    // TODO: Debt strategies heavily rely on keepers to maintain a healthy ratio.

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        // TODO: Critical: Use currentCRate().
        // TODO: Only borrow more if overcollateralized. Return borrowed if undercollateralized, otherwise it can get liquidated
        uint256 balance = balanceOfWant();
        if (balance > 0) {
            _checkAllowance(address(yVault), address(mim), balance);
            borrowMIMToTargetCRate();

            if (balanceOfMIM() > DUST_THRESHOLD) {
                yVault.deposit();
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded) //in collateral
    internal
    override
    returns (uint256 _liquidatedAmount, uint256 _loss)
    {

        uint256 wantBal = balanceOfWant();

        if (wantBal >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        //need to convert _amountNeeded from collateral to yVault token
        uint256 _amountToWithdaw = collateralToMIM(_amountNeeded.sub(wantBal));
        _withdrawFromYVault(_amountToWithdaw);

        if (_amountToWithdaw > balanceOfMIM()) {
            repayMIM(balanceOfMIM());
        }

        uint256 bbRemainingBalance = balanceOfMIMInBentoBox();
        if (bbRemainingBalance > minMIMToSell) {
            removeMIMFromBentoBox();
        }

        _exchangeMIMToCollateral(balanceOfMIM());

        uint256 looseWant = balanceOfWant();

        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions()
    internal
    override
    returns (uint256 _amountFreed)
    {
        liquidatePosition(estimatedTotalAssets());

        _amountFreed = balanceOfWant();
    }

    //event new_values(uint256 collateralAmount, uint256 borrowedAmount);
    function estimatedTotalAssets() public view override returns (uint256)  {
        uint256 balanceOfMIMInBB = balanceOfMIMInBentoBox();

        uint256 remainingCollateral = collateralAmount() == 0 ? 0 : collateralAmount().sub(borrowedAmount());
        uint256 totalMIM = valueOfInvestment().add(balanceOfMIMInBB).add(remainingCollateral);

        return
        balanceOfWant().add(mimToCollateral(totalMIM));
    }

    function prepareMigration(address _newStrategy) internal override {
        targetCollatRate = 0;

        _withdrawFromYVault(collateralAmount());
        repayMIM(collateralAmount());

        uint256 _balanceOfMIM = balanceOfMIM();
        if (_balanceOfMIM > 0) {
            mim.safeTransfer(
                _newStrategy,
                _balanceOfMIM
            );
        }
        if (balanceOfMIMInBentoBox() > 0) {
            transferAllBentoBalance(_newStrategy);
        }
        super.prepareMigration(_newStrategy);
    }

    function _ethToWant(uint256 _amount) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = collateralAsVault.token();
        uint256[] memory amounts =
        uniswapRouter.getAmountsOut(_amount, path);

        return _fromUnderlyingTokenToYVVault(amounts[amounts.length - 1]);
    }

    function _fromUnderlyingTokenToYVVault(uint256 _amount) internal view returns (uint256) {
        // TODO: missing return
        _amount.mul(10 ** collateralAsVault.decimals()).div(collateralAsVault.pricePerShare());
    }

    /*********************** Setters Functions ***********************/

    function setTargetCollateralRate(uint256 _targetCollatRate) public onlyVaultManagers {
        targetCollatRate = _targetCollatRate;
    }
}
