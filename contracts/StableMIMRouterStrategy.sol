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
}

interface IAbracadabra {
    function bentoBox() external returns (IBentoBoxV1);
    function masterContract() external returns (address);
    function addCollateral(address to, bool skim, uint256 share) external;
    function removeCollateral(address to, uint256 share) external;
    function borrow(address to, uint256 amount) external returns (uint256 part, uint256 share);
    function repay(address to, bool skim, uint256 part) external returns (uint256 amount);
    function magicInternetMoney() external returns (IERC20 mim);
}

contract StableMIMRouterStrategy is RouterStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 private mim;
    IAbracadabra private abracadabra;
    IBentoBoxV1 private bentoBox;
    uint256 private constant TARGET_C_RATE = 90000; // 90%
    uint256 private constant CURRENT_C_RATE = 90000; // 90%
    uint256 private constant C_RATE_PRECISION = 1e5;

    uint256 private constant DUST_THRESHOLD = 10_000;
    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant uniswapRouter =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    uint256 public constant DENOMINATOR = 10_000;

    constructor(
        address _vault,
        address _yVault,
        string memory _strategyName,
        address _abracadabra
    ) public RouterStrategy(_vault, _yVault, _strategyName) {
        _initializeStableMIMRouterRouter(_abracadabra);
    }

    event FullCloned(address indexed clone);

    function cloneStableMIMRouter(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yVault,
        address _abracadabra,
        string memory _strategyName
    ) external returns (address newStrategy) {
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

        StableMIMRouterStrategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _yVault,
            _abracadabra,
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
        _initializeStableMIMRouterRouter(_abracadabra);
    }

    function _initializeStableMIMRouterRouter(address _abracadabra)
        internal
    {
        abracadabra = IAbracadabra(_abracadabra);
        bentoBox = IBentoBoxV1(abracadabra.bentoBox());
        mim = abracadabra.magicInternetMoney();
        // TODO: check that this abracadabra uses same coin as want
         _setupStatics();
    }

    function _setupStatics() internal {
        debtThreshold = 80 * 1e18;
        maxLoss = 1;
        bentoBox.setMasterContractApproval(address(this), abracadabra.masterContract(), true, 0,0,0);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 balance = balanceOfWant();
        if (balance > 0) {
            _checkAllowance(address(yVault), address(mim), balance);
            borrowMIM(balance.mul(TARGET_C_RATE).div(C_RATE_PRECISION));
            // TODO: when there is a vault
            yVault.deposit();
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBal = balanceOfWant();

        if (wantBal >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 toWithdraw = _amountNeeded.sub(wantBal);

        //todo: WHEN THERE IS A yVault
        //_withdrawFromYVault(wantToCurveToken(toWithdraw));
        repayMIM(mim.balanceOf(address(this)));

        uint256 looseWant = balanceOfWant();
        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function repayMIM(uint256 _amountToRepay)
        internal {
        // TODO = fix;
        _amountToRepay = Math.min(_amountToRepay, mim.balanceOf(address(this)));
        _checkAllowance(address(bentoBox), address(mim), _amountToRepay);
        bentoBox.deposit(mim, address(this), address(this), _amountToRepay, 0);
        abracadabra.repay(address(this), true, _amountToRepay);
        abracadabra.removeCollateral(address(this), _amountToRepay);
        bentoBox.withdraw(want, address(this), address(this), bentoBox.balanceOf(want, address(this)), 0);
    }

    function borrowMIM(uint256 _amountToBorrow)
        internal {
        // TODO: fix
        _checkAllowance(address(bentoBox), address(want), _amountToBorrow);
        bentoBox.deposit(want, address(this), address(this), _amountToBorrow, 0);
        abracadabra.addCollateral(address(this), false, _amountToBorrow);
        abracadabra.borrow(address(this), _amountToBorrow);
        bentoBox.withdraw(mim, address(this), address(this), bentoBox.balanceOf(mim, address(this)), 0);
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
        return
            balanceOfWant().add(valueOfInvestment());
    }

    function _ethToWant(uint256 _amount) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(VaultAPI(address(want)).token());
        uint256[] memory amounts =
            IUni(uniswapRouter).getAmountsOut(_amount, path);

        return _fromStableTokenToYVVault(amounts[amounts.length - 1]);
    }

    function _fromStableTokenToYVVault(uint256 _amount) internal view returns (uint256) {
        VaultAPI _want = VaultAPI(address(want));
        _amount.mul(10**_want.decimals()).div(_want.pricePerShare());
    }

    function _fromYVVaultToStableToken(uint256 _amount) internal view returns (uint256) {
        VaultAPI _want = VaultAPI(address(want));
        _amount.mul(_want.pricePerShare()).div(10**_want.decimals());
    }
}
