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

interface IRouter {
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
    function exchangeRate() external view returns (uint256);
    function userBorrowPart(address) external view returns (uint256);
    function userCollateralShare(address) external view returns (uint256);
    function totalBorrow() external view returns (Rebase memory totals);
    function collateral() external view returns (address);
    function accrue() external;
}

interface IWETH is IERC20 {
     function withdraw(uint wad) external;
}

interface ICurveFI {
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external payable returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function coins(uint256 i) external returns (address);
}

contract MIMMinterRouterStrategy is RouterStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;


    IAbracadabra private abracadabra;
    IBentoBoxV1 private bentoBox;
    uint256 public targetCollatRate;
    uint256 private maxCollatRate;
    uint256 private minMIMToSell;
    VaultAPI private wantAsVault;

    uint256 private constant C_RATE_PRECISION = 1e5;
    uint256 private constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 private constant DUST_THRESHOLD = 10_000;
    IWETH public constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 private constant mim = IERC20(0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3);
    IRouter public constant uniswapRouter =
        IRouter(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    ICurveFI private constant crvMIM = ICurveFI(0x5a6A4D54456819380173272A5E8E9B9904BdF41B);

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
        maxCollatRate = _maxCollatRate;
        targetCollatRate = _targetCollatRate;
        require(abracadabra.collateral() == address(want));
        require(targetCollatRate < maxCollatRate);
        wantAsVault = VaultAPI(address(want));

         _setupStatics();
    }

    function _setupStatics() internal {
        maxLoss = 1;
        minMIMToSell = 500*(10**18);
        bentoBox.setMasterContractApproval(address(this), abracadabra.masterContract(), true, 0,0,0);

        dai.safeApprove(address(uniswapRouter), type(uint256).max);
        mim.safeApprove(address(crvMIM), type(uint256).max);

        //steth.safeApprove(address(crvSTETH), uint256(-1));
        //mim.safeApprove(address(crvMIM), uint256(-1));
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
        _withdrawFromYVault((_amountNeeded.sub(wantBal)).div(abracadabra.exchangeRate()).mul(EXCHANGE_RATE_PRECISION));

        repayMIM(mim.balanceOf(address(this)));

        uint256 bbRemainingBalance = bentoBox.balanceOf(mim, address(this));
        if(bbRemainingBalance > minMIMToSell) {
            bentoBox.withdraw(mim, address(this), address(this), bbRemainingBalance, 0);
        }
        _disposeOfMIM();

        uint256 looseWant = balanceOfWant();
        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function repayMIM(uint256 _amountToRepay)
        public {
        abracadabra.accrue();//need to compute pending interest
        Rebase memory _totalBorrow = abracadabra.totalBorrow();
        uint256 owed = borrowedAmount();

        _amountToRepay = Math.min(_amountToRepay, owed);

        uint256 _amountToDepositInBB = _amountToRepay.sub(bentoBox.balanceOf(mim, address(this)));
        _amountToDepositInBB = Math.min(_amountToDepositInBB, mim.balanceOf(address(this)));

        _checkAllowance(address(bentoBox), address(mim), _amountToDepositInBB);

        bentoBox.deposit(mim, address(this), address(this), _amountToDepositInBB, 0);

        //repay receives a part, so we need to calculate the part to repay
        uint256 part = RebaseLibrary.toBase(_totalBorrow, _amountToRepay, true);

        abracadabra.repay(address(this), false, Math.min(part, abracadabra.userBorrowPart(address(this))));

        // we need to withdraw enough to keep our c-rate
        uint256 amountFreeToWithdraw = collateralAmount().sub(borrowedAmount().div(targetCollatRate).mul(C_RATE_PRECISION));
        uint256 collateralToWithdraw = bentoBox.toShare(want, amountFreeToWithdraw.mul(abracadabra.exchangeRate()).div(EXCHANGE_RATE_PRECISION), true);

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
        uint256 toBorrow = collateralAmount().mul(targetCollatRate).div(C_RATE_PRECISION).sub(borrowedAmount());
        borrowMIM(toBorrow);
    }

    function currentCRate() public view returns (uint256 _collateralRate) {
        if (collateralAmount() == 0) return 0;
        _collateralRate = borrowedAmount().mul(C_RATE_PRECISION).div(collateralAmount());
    }

    function collateralAmount() public view returns (uint256 _collateralAmount) {
        uint256 collateralShare = abracadabra.userCollateralShare(address(this));
        _collateralAmount = bentoBox.toAmount(
            want,
            collateralShare.mul(EXCHANGE_RATE_PRECISION).div(abracadabra.exchangeRate()),
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
        uint256 balanceOfMIMInBB = bentoBox.balanceOf(mim, address(this));
        uint256 remainingCollateral = collateralAmount().sub(borrowedAmount());

        uint256 totalMIM = valueOfInvestment().add(balanceOfMIMInBB).add(remainingCollateral);

        return
            balanceOfWant().add(totalMIM.mul(abracadabra.exchangeRate()).div(EXCHANGE_RATE_PRECISION));
    }

    function _ethToWant(uint256 _amount) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = wantAsVault.token();
        uint256[] memory amounts =
            uniswapRouter.getAmountsOut(_amount, path);

        return _fromUnderlyingTokenToYVVault(amounts[amounts.length - 1]);
    }

    function _fromUnderlyingTokenToYVVault(uint256 _amount) internal view returns (uint256) {
        _amount.mul(10**wantAsVault.decimals()).div(wantAsVault.pricePerShare());
    }

    /* function _fromYVVaultToUnderlyingToken(uint256 _amount) internal view returns (uint256) {
        _amount.mul(wantAsVault.pricePerShare()).div(10**wantAsVault.decimals());
    } */

    function setTargetCollateralRate(uint256 _targetCollatRate) public onlyVaultManagers {
        targetCollatRate = _targetCollatRate;
    }

    receive() external payable {}
    //sell mim function
    // due to liquidity issues, the best path is mim -> 3crv -> dai -> eth
    function _disposeOfMIM() internal virtual  {
        uint256 _mim = mim.balanceOf(address(this));
        if (_mim > minMIMToSell) {
            address[] memory path = new address[](2);
            path[0] = address(dai);
            path[1] = address(weth);

            crvMIM.exchange_underlying(int128(0), int128(1), _mim, 0);

            uniswapRouter.swapExactTokensForETH(dai.balanceOf(address(this)), 0, path, address(this), now);
            crvSTETH.add_liquidity{value: address(this).balance}([address(this).balance, 0], 0);

            IERC20 crvSTETHLPtoken = IERC20(wantAsVault.token());

            _checkAllowance(address(wantAsVault), address(crvSTETHLPtoken), uint256(-1));

            wantAsVault.deposit();
        }
    }
}
