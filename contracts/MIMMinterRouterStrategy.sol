// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {yToken} from "@yearnvaults/contracts/yToken.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "../libraries/BoringMath.sol";
import "../libraries/BoringRebase.sol";
import "./RouterStrategy.sol";

interface VaultAPI is IERC20 {
    function decimals() external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    function token() external view returns (address);
    function deposit() external;
}

interface IBentoBoxV1 {
    function balanceOf(IERC20, address) external view returns (uint256);

    function deposit(
        IERC20 token_,
        address from,
        address to,
        uint256 amount,
        uint256 share
    ) external payable returns (uint256 amountOut, uint256 shareOut);

    function setMasterContractApproval(
        address user,
        address masterContract,
        bool approved,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function toAmount(
        IERC20 token,
        uint256 share,
        bool roundUp
    ) external view returns (uint256 amount);

    function toShare(
        IERC20 token,
        uint256 amount,
        bool roundUp
    ) external view returns (uint256 share);

    function totals(IERC20) external view returns (Rebase memory totals_);

    function withdraw(
        IERC20 token_,
        address from,
        address to,
        uint256 amount,
        uint256 share
    ) external returns (uint256 amountOut, uint256 shareOut);
}

interface IUni {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

}

interface IAbracadabra {
    function bentoBox() external returns (IBentoBoxV1);
    function masterContract() external returns (address);
    function addCollateral(address to, bool skim, uint256 share) external;
    function removeCollateral(address to, uint256 share) external;
    function borrow(address to, uint256 amount) external returns (uint256 part, uint256 share);
    function repay(address to, bool skim, uint256 part) external returns (uint256 amount);
    function magicInternetMoney() external returns (IERC20 mim);
    function exchangeRate() external view returns (uint256);
    function userBorrowPart(address) external view returns (uint256);
    function userCollateralShare(address) external view returns (uint256);
    function totalBorrow() external view returns (Rebase memory totals);
    function collateral() external view returns (address);
}

interface IWETH is IERC20 {
     function withdraw(uint wad) external;
     //function balanceOf(address) external returns (uint256);
}

interface ICurveFI {
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external payable returns (uint256);
}

contract MIMMinterRouterStrategy is RouterStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 private mim;
    IAbracadabra private abracadabra;
    IBentoBoxV1 private bentoBox;
    uint256 public targetCollatRate;
    uint256 private maxCollatRate;
    uint256 private minMIMToSell;
    VaultAPI private wantAsVault;

    uint256 private constant C_RATE_PRECISION = 1e5;
    uint256 private constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 private constant DUST_THRESHOLD = 10_000;
    IERC20 public constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant steth = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address public constant uniswapRouter =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    ICurveFI private constant crvSTETH = ICurveFI(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);


    constructor(
        address _vault,
        address _yVault,
        string memory _strategyName,
        address _abracadabra,
        uint256 _maxCollatRate,
        uint256 _targetCollatRate
    ) public RouterStrategy(_vault, _yVault, _strategyName) {
        _initializeMIMMinterRouterRouter(_abracadabra, _maxCollatRate, _targetCollatRate);
    }

    event FullCloned(address indexed clone);

    function cloneMIMMinter(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yVault,
        address _abracadabra,
        uint256 _maxCollatRate,
        uint256 _targetCollatRate,
        string memory _strategyName
    ) external returns (address payable newStrategy) {
        require(isOriginal);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        MIMMinterRouterStrategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _yVault,
            _abracadabra,
            _maxCollatRate,
            _targetCollatRate,
            _strategyName
        );

        emit FullCloned(newStrategy);
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
        _initializeMIMMinterRouterRouter(_abracadabra, _maxCollatRate, _targetCollatRate);
    }

    function _initializeMIMMinterRouterRouter(address _abracadabra, uint256 _maxCollatRate, uint256 _targetCollatRate)
        internal
    {
        abracadabra = IAbracadabra(_abracadabra);
        bentoBox = IBentoBoxV1(abracadabra.bentoBox());
        mim = abracadabra.magicInternetMoney();
        maxCollatRate = _maxCollatRate;
        targetCollatRate = _targetCollatRate;
        require(abracadabra.collateral() == address(want));
        require(targetCollatRate < maxCollatRate);
        wantAsVault = VaultAPI(address(want));

         _setupStatics();
    }

    function _setupStatics() internal {
        maxLoss = 1;
        minMIMToSell = 1_000*(10**18);
        bentoBox.setMasterContractApproval(address(this), abracadabra.masterContract(), true, 0,0,0);

        mim.safeApprove(uniswapRouter, uint256(-1));
        steth.safeApprove(address(crvSTETH), uint256(-1));
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 balance = balanceOfWant();
        if (balance > 0) {
            _checkAllowance(address(yVault), address(mim), balance);
            borrowMIMToTargetCRate();

            if (mim.balanceOf(address(this)) > DUST_THRESHOLD) {
                yVault.deposit();
            }
        }
    }

    /* //in collateral
    function externalLiquidatePosition(uint256 _amountNeeded) public returns (uint256 _liquidatedAmount, uint256 _loss) {
        return liquidatePosition(_amountNeeded);
    } */

    event looseWant2(uint256 amountNeeded, uint256 looseWant, uint256 toWithdraw, uint256 exchangeRate, uint256 EXCHANGE_RATE_PRECISION);
    function liquidatePosition(uint256 _amountNeeded) //in collateral
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBal = balanceOfWant();

        if (wantBal >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 toWithdraw = _amountNeeded.sub(wantBal);

        //need to convert _amountNeeded from collateral to yVault token
        uint256 exchangeRate = abracadabra.exchangeRate();
        _withdrawFromYVault(toWithdraw.div(exchangeRate).mul(EXCHANGE_RATE_PRECISION));

        repayMIM(mim.balanceOf(address(this)));

        uint256 bbRemainingBalance = bentoBox.balanceOf(mim, address(this));
        if(bbRemainingBalance > minMIMToSell) {
            bentoBox.withdraw(mim, address(this), address(this), bbRemainingBalance, 0);
        }
        _disposeOfMIM();
        emit looseWant2(_amountNeeded, balanceOfWant(), toWithdraw, exchangeRate, EXCHANGE_RATE_PRECISION);

        uint256 looseWant = balanceOfWant();
        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    event repayNumbers(uint256 amountFreeToWithdraw, uint256 collateralToWithdraw, uint256 part, uint256 userCollateralShare);
    function repayMIM(uint256 _amountToRepay)
        public {
        Rebase memory _totalBorrow = abracadabra.totalBorrow();
        uint256 owed = borrowedAmount();
        uint256 exchangeRate = abracadabra.exchangeRate();

        _amountToRepay = Math.min(_amountToRepay, owed);

        uint256 _amountToDepositInBB = _amountToRepay.sub(bentoBox.balanceOf(mim, address(this)));
        _amountToDepositInBB = Math.min(_amountToDepositInBB, mim.balanceOf(address(this)));

        _checkAllowance(address(bentoBox), address(mim), _amountToDepositInBB);

        bentoBox.deposit(mim, address(this), address(this), _amountToDepositInBB, 0);

        //repay receives a part, so we need to calculate the part to repay
        uint256 part = RebaseLibrary.toBase(_totalBorrow, _amountToRepay*99/100, false);
        uint256 userborrowed = abracadabra.userBorrowPart(address(this));
        abracadabra.repay(address(this), false, part);

        // we need to withdraw enough to keep our c-rate
        uint256 amountFreeToWithdraw = collateralAmount().sub(borrowedAmount().div(targetCollatRate).mul(C_RATE_PRECISION));
        uint256 collateralToWithdraw = bentoBox.toShare(want, amountFreeToWithdraw.mul(exchangeRate).div(EXCHANGE_RATE_PRECISION), true);

        emit repayNumbers(amountFreeToWithdraw, collateralToWithdraw, part, userborrowed);
        abracadabra.removeCollateral(address(this), collateralToWithdraw);
        bentoBox.withdraw(want, address(this), address(this), bentoBox.balanceOf(want, address(this)), 0);
    }

    function borrowMIM(uint256 _amountToBorrow)
        public {
        // won't be able to borrow more than available supply
        _amountToBorrow = Math.min(_amountToBorrow, bentoBox.balanceOf(mim, address(abracadabra)));

        uint256 mimToBorrow = bentoBox.toShare(mim, _amountToBorrow, false);

        abracadabra.borrow(address(this), mimToBorrow);
        bentoBox.withdraw(mim, address(this), address(this), bentoBox.balanceOf(mim, address(this)), 0);
    }

    function addFullCollateral() public {
        uint256 _balanceOfWant = balanceOfWant();
        _checkAllowance(address(bentoBox), address(want), _balanceOfWant);
        bentoBox.deposit(want, address(this), address(this), _balanceOfWant, 0);
        abracadabra.addCollateral(address(this), false, _balanceOfWant);
    }

    function borrowMIMToTargetCRate() public {
        addFullCollateral();

        uint256 _collateral = collateralAmount();
        uint256 _borrowedAmount = borrowedAmount();
        uint256 toBorrow = _collateral.mul(targetCollatRate).div(C_RATE_PRECISION).sub(_borrowedAmount);

        borrowMIM(toBorrow);
    }

    function currentCRate() public view returns (uint256 _collateralRate) {
        if (collateralAmount() == 0) return 0;
        _collateralRate = borrowedAmount().mul(C_RATE_PRECISION).div(collateralAmount());
    }

    function collateralAmount() public view returns (uint256 _collateralAmount) {
        uint256 collateralShare = abracadabra.userCollateralShare(address(this));
        uint256 exchangeRate = abracadabra.exchangeRate();
        _collateralAmount = bentoBox.toAmount(
            want,
            collateralShare.mul(EXCHANGE_RATE_PRECISION).div(exchangeRate),
            false
        );
    }

    function borrowedAmount() public view returns (uint256 _borrowedAmount) {
        uint256 borrowPart = abracadabra.userBorrowPart(address(this));

        Rebase memory _totalBorrow = abracadabra.totalBorrow();
        _borrowedAmount = borrowPart.mul(_totalBorrow.elastic) / _totalBorrow.base;
    }


    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        yVault.withdraw(
            yVault.balanceOf(address(this)),
            address(this),
            maxLoss
        );
        repayMIM(mim.balanceOf(address(this)));

        _amountFreed = balanceOfWant();
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 exchangeRate = abracadabra.exchangeRate();
        uint256 balanceOfMIMInBB = bentoBox.balanceOf(mim, address(this));
        uint256 mimInVault = valueOfInvestment();
        uint256 remainingCollateral = collateralAmount().sub(borrowedAmount());

        uint256 totalMIM = mimInVault.add(balanceOfMIMInBB).add(remainingCollateral);

        return
            balanceOfWant().add(totalMIM.mul(exchangeRate).div(EXCHANGE_RATE_PRECISION));
    }

    function _ethToWant(uint256 _amount) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = wantAsVault.token();
        uint256[] memory amounts =
            IUni(uniswapRouter).getAmountsOut(_amount, path);

        return _fromUnderlyingTokenToYVVault(amounts[amounts.length - 1]);
    }

    function _fromUnderlyingTokenToYVVault(uint256 _amount) internal view returns (uint256) {
        _amount.mul(10**wantAsVault.decimals()).div(wantAsVault.pricePerShare());
    }

    function _fromYVVaultToUnderlyingToken(uint256 _amount) internal view returns (uint256) {
        _amount.mul(wantAsVault.pricePerShare()).div(10**wantAsVault.decimals());
    }

    function setTargetCollateralRate(uint256 _targetCollatRate) public onlyVaultManagers {
        targetCollatRate = _targetCollatRate;
    }

    receive() external payable {}
    //sell mim function
    function _disposeOfMIM() internal virtual  {
        uint256 _mim = mim.balanceOf(address(this));

        if (_mim > minMIMToSell) {
            address[] memory path = new address[](3);
            path[0] = address(mim);
            path[1] = address(weth);
            path[2] = address(steth);

            IUni(uniswapRouter).swapExactTokensForTokens(_mim, uint256(0), path, address(this), now);
            uint256 stethBalance = steth.balanceOf(address(this));

            uint256 amounts1 =  address(this).balance;
            uint256 amounts2 = stethBalance;

            crvSTETH.add_liquidity{value: amounts1}([amounts1, amounts2], 0);

            IERC20 crvSTETH1 = IERC20(wantAsVault.token());

            _checkAllowance(address(wantAsVault), address(crvSTETH1), uint256(-1));

            wantAsVault.deposit();
        }
    }
}
