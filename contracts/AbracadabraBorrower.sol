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
import "../libraries/BoringMath.sol";
import "../libraries/BoringRebase.sol";
import "./RouterStrategy.sol";

interface VaultAPI is IERC20 {
    function decimals() external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    function token() external view returns (address);
    function deposit() external;
    function withdraw(uint256 amount) external;
}

interface IBentoBoxV1 {
    function balanceOf(IERC20, address) external view returns (uint256);
    function transfer(
            IERC20 token,
            address from,
            address to,
            uint256 share
        ) external;

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

    function flashLoan(
        IFlashBorrower borrower,
        address receiver,
        IERC20 token,
        uint256 amount,
        bytes calldata data
    ) external;
}

interface IRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactETHForTokens(
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
    // TODO: function COLLATERIZATION_RATE() external view returns (uint);
    // TODO: add view for bentoBox(), masterContract()
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
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function coins(uint256 i) external returns (address);
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 _min_amount) external returns (uint256);
}

interface IFlashBorrower {
    /// @notice The flashloan callback. `amount` + `fee` needs to repayed to msg.sender before this call returns.
    /// @param sender The address of the invoker of this flashloan.
    /// @param token The address of the token that is loaned.
    /// @param amount of the `token` that is loaned.
    /// @param fee The fee that needs to be paid on top for this loan. Needs to be the same as `token`.
    /// @param data Additional data that was passed to the flashloan function.
    function onFlashLoan(
        address sender,
        IERC20 token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;
}

contract AbracadabraBorrower is IFlashBorrower {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IAbracadabra private abracadabra;
    IBentoBoxV1 private bentoBox;
    uint256 public targetCollatRate;
    uint256 private maxCollatRate;
    uint256 internal minMIMToSell;
    bool private underlying_is_lp;
    IERC20 private collateral;
    VaultAPI internal collateralAsVault;

    uint256 private constant C_RATE_PRECISION = 1e5;
    uint256 private constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 internal constant DUST_THRESHOLD = 10_000;

    IWETH public constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 internal constant mim = IERC20(0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3);
    IRouter public constant uniswapRouter =
        IRouter(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    ICurveFI private constant crvMIM = ICurveFI(0x5a6A4D54456819380173272A5E8E9B9904BdF41B);

    ICurveFI private constant crvSTETH = ICurveFI(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);


    function _initializeAbracadabraBorrower(address _abracadabra, uint256 _maxCollatRate, uint256 _targetCollatRate, bool _underlying_is_lp)
        internal
    {
        abracadabra = IAbracadabra(_abracadabra);
        bentoBox = IBentoBoxV1(abracadabra.bentoBox());
        // TODO: maxCollatRate = abracadabra.COLLATERIZATION_RATE(); instead of initializing this yourself. Can be removed from constructor
        maxCollatRate = _maxCollatRate;
        // TODO: Should add a require(targetCollatRate < maxCollatRate);
        // TODO: Also recommend adding an additional param
        targetCollatRate = _targetCollatRate;
        require(targetCollatRate < maxCollatRate);
        collateral = IERC20(abracadabra.collateral());
        collateralAsVault = VaultAPI(address(collateral));

        underlying_is_lp = _underlying_is_lp;


        minMIMToSell = 500*(10**18);
        bentoBox.setMasterContractApproval(address(this), abracadabra.masterContract(), true, 0,0,0);

        collateral.safeApprove(address(bentoBox), type(uint256).max);
        mim.safeApprove(address(bentoBox), type(uint256).max);
        dai.safeApprove(address(uniswapRouter), type(uint256).max);
        mim.safeApprove(address(crvMIM), type(uint256).max);
        if(underlying_is_lp) {
            IERC20 lPtoken = IERC20(collateralAsVault.token());
            lPtoken.safeApprove(address(collateralAsVault), uint256(-1));
        }

    }

    function onFlashLoan(
        address sender,
        IERC20 token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override {
        repayMIM(amount);
        uint256 collateralBalance = balanceOfCollateral();
        uint256 exchangeRate = abracadabra.exchangeRate();
        uint256 neededCollateral = mimToCollateral(amount.add(fee));

        _exchangeCollateralToMIM(neededCollateral);

        mim.safeTransfer(msg.sender, amount.add(fee));
    }

    /*********************** Borrow and Repay Functions ***********************/
    function repayMIM(uint256 _amountToRepay)
        internal {
        abracadabra.accrue();//need to compute pending interest
        Rebase memory _totalBorrow = abracadabra.totalBorrow();
        uint256 owed = borrowedAmount();

        _amountToRepay = Math.min(_amountToRepay, owed);

        uint256 _amountToDepositInBB = _amountToRepay.sub(balanceOfMIMInBentoBox());

        // if we don't have enough mim, we need a loan to repay
        if(owed >= balanceOfMIM()){
            bentoBox.flashLoan(this, address(this), mim, owed.sub(balanceOfMIM()), "");
        }

        _amountToDepositInBB = Math.min(_amountToDepositInBB, balanceOfMIM());

        bentoBox.deposit(mim, address(this), address(this), _amountToDepositInBB, 0);

        //repay receives a part, so we need to calculate the part to repay
        uint256 part = RebaseLibrary.toBase(_totalBorrow, Math.min(_amountToRepay, balanceOfMIMInBentoBox()), true);

        abracadabra.repay(address(this), false, Math.min(part, abracadabra.userBorrowPart(address(this))));

        // we need to withdraw enough to keep our c-rate
        uint256 _collatRate = targetCollatRate == 0 ? (maxCollatRate-500):targetCollatRate;

        uint256 _neededCollateralAmount = borrowedAmount().div(_collatRate).mul(C_RATE_PRECISION);
        uint256 _collateralAmount = collateralAmount();
        uint256 amountFreeToWithdraw = (_collateralAmount >= _neededCollateralAmount) ? (_collateralAmount.sub(_neededCollateralAmount)):0;
        uint256 collateralToWithdraw = bentoBox.toShare(collateral, mimToCollateral(amountFreeToWithdraw), true);

        if(collateralToWithdraw > 0) {
            abracadabra.removeCollateral(address(this), collateralToWithdraw);
            bentoBox.withdraw(collateral, address(this), address(this), balanceOfCollateralInBentoBox(), 0);
        }
    }

    function borrowMIM(uint256 _amountToBorrow)
        internal {
        if (_amountToBorrow == 0) return;
        // won't be able to borrow more than available supply
        _amountToBorrow = Math.min(_amountToBorrow, bentoBox.balanceOf(mim, address(abracadabra)));

        uint256 mimToBorrow = bentoBox.toShare(mim, _amountToBorrow, false);

        abracadabra.borrow(address(this), mimToBorrow);
        bentoBox.withdraw(mim, address(this), address(this), balanceOfMIMInBentoBox(), 0);
    }

    function borrowMIMToTargetCRate() internal {
        uint256 _balanceOfCollateral = balanceOfCollateral();
        // TODO: I think _balanceOfCollateral != shares?
        // TODO: (uint256 amountOut, uint256 sharesOut) = bentoBox.deposit(collateral, address(this), address(this), _balanceOfCollateral, 0);
        // TODO: abracadabra.addCollateral(address(this), false, sharesOut);
        bentoBox.deposit(collateral, address(this), address(this), _balanceOfCollateral, 0);
        abracadabra.addCollateral(address(this), false, _balanceOfCollateral);

        uint256 toBorrow = collateralAmount().mul(targetCollatRate).div(C_RATE_PRECISION).sub(borrowedAmount());
        borrowMIM(toBorrow);
    }


    /*********************** Views Functions ***********************/

    function currentCRate() public view returns (uint256 _collateralRate) {
        if (collateralAmount() == 0) return 0;
        _collateralRate = borrowedAmount().mul(C_RATE_PRECISION).div(collateralAmount());
    }

    function collateralAmount() public view returns (uint256 _collateralAmount) {
        uint256 collateralShare = abracadabra.userCollateralShare(address(this));
        _collateralAmount = bentoBox.toAmount(
            collateral,
            collateralToMIM(collateralShare),
            false
        );
    }

    function borrowedAmount() public view returns (uint256 _borrowedAmount) {
        uint256 borrowPart = abracadabra.userBorrowPart(address(this));

        Rebase memory _totalBorrow = abracadabra.totalBorrow();
        _borrowedAmount = borrowPart.mul(_totalBorrow.elastic) / _totalBorrow.base;
    }

    function balanceOfCollateral() private view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    function balanceOfMIM() internal view returns (uint256){
        return mim.balanceOf(address(this));
    }

    function balanceOfMIMInBentoBox() internal view returns (uint256){
        return bentoBox.balanceOf(mim, address(this));
    }

    function balanceOfCollateralInBentoBox() internal view returns (uint256){
        return bentoBox.balanceOf(collateral, address(this));
    }

    function mimToCollateral(uint256 _mimAmount) internal view returns (uint256){
        return _mimAmount.mul(abracadabra.exchangeRate()).div(EXCHANGE_RATE_PRECISION);
    }

    function collateralToMIM(uint256 _collateralAmount) internal view returns (uint256){
        return _collateralAmount.div(abracadabra.exchangeRate()).mul(EXCHANGE_RATE_PRECISION);
    }

    /*********************** Other Functions ***********************/

    function removeMIMFromBentoBox() internal {
        bentoBox.withdraw(mim, address(this), address(this), balanceOfMIMInBentoBox(), 0);
    }

    function removeCollateralFromBentoBox() internal {
        bentoBox.withdraw(collateral, address(this), address(this), balanceOfCollateralInBentoBox(), 0);
    }

    function transferAllBentoBalance(address newDestination) internal {
        bentoBox.transfer(mim, address(this), newDestination, balanceOfMIMInBentoBox());
        bentoBox.transfer(collateral, address(this), newDestination, balanceOfCollateralInBentoBox());
    }


    /*********************** Exchangers Functions ***********************/

    function _exchangeCollateralToMIM(uint256 _collateralToExchange) internal {
        //1. unwrap from vault
        collateralAsVault.withdraw(_collateralToExchange);

        //2. optional: break lp
        IERC20 crvSTETHLPtoken = IERC20(collateralAsVault.token());
        crvSTETH.remove_liquidity_one_coin(crvSTETHLPtoken.balanceOf(address(this)), 0, 0);

        //3. underlying token <> mim

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(dai);

        uniswapRouter.swapExactETHForTokens(weth.balanceOf(address(this)), 0, path, address(this), now);

        crvMIM.exchange_underlying(int128(1), int128(0), dai.balanceOf(address(this)), 0);
    }

    receive() external payable {}
    //sell mim function
    // due to liquidity issues, the best path is mim -> 3crv -> dai -> eth
    function _exchangeMIMToCollateral(uint256 _mimToExchange) internal  {

        if (_mimToExchange > minMIMToSell) {
            address[] memory path = new address[](2);
            path[0] = address(dai);
            path[1] = address(weth);

            crvMIM.exchange_underlying(int128(0), int128(1), _mimToExchange, 0);

            uniswapRouter.swapExactTokensForETH(dai.balanceOf(address(this)), 0, path, address(this), now);
            crvSTETH.add_liquidity{value: address(this).balance}([address(this).balance, 0], 0);

            IERC20 crvSTETHLPtoken = IERC20(collateralAsVault.token());

            collateralAsVault.deposit();
        }
    }
}
