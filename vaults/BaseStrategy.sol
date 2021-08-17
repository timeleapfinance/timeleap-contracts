// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./libs/IStrategyTime.sol";
import "./libs/IUniPair.sol";
import "./libs/IUniRouter02.sol";

abstract contract BaseStrategy is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public wantAddress;
    address public token0Address;
    address public token1Address;
    address public earnedAddress;

    address public uniRouterAddress;
    address public constant usdcAddress = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174; // USDC token contract
    address public constant timeAddress = 0x5c59D7Cb794471a9633391c4927ADe06B8787a90; // TIME token contract
    address public constant rewardAddress = 0x1F7c88A37f7d0B36E7547E3a79c2D04F90531E75; // Fee Address (held by devWallet)
    address public constant withdrawFeeAddress = 0x1c54019Abc98b07FfB5eE8C082bED89A65Df7e1D; // Withdrawal Fee Address (held by devWallet)
    address public constant feeAddress = 0x1F7c88A37f7d0B36E7547E3a79c2D04F90531E75; // Fee Address (held by devWallet)
    address public vaultChefAddress;
    address public govAddress;

    uint256 public lastEarnBlock = block.number;
    uint256 public sharesTotal = 0;

    address public constant treasuryAddress = 0x374BD17C475f972D6aF4EA0fAC0744B5500A959F; // Treasury Contract Address, behind 28-day Timelock
    address public constant masterchefAddress = 0x41C4dFA389e8c43BA6220aa62021ed246d441306; // TIME MasterChef contract

    uint256 public controllerFee = 50; // 0.5%
    uint256 public rewardRate = 0;
    uint256 public buyBackRate = 450; // 4.5% of all emissions are being used to buyback TIME
    uint256 public constant feeMaxTotal = 1000;
    uint256 public constant feeMax = 10000; // 100 = 1%, 10000 = 100%

    uint256 public withdrawFeeFactor = 10000; // NO Withdrawal Fees
    uint256 public constant withdrawFeeFactorMax = 10000;
    uint256 public constant withdrawFeeFactorLL = 9900; // Max 1% withdrawal fee (lower limit)

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public earnedToWmaticPath;
    address[] public earnedToUsdcPath;
    address[] public earnedToTimePath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;

    event SetSettings(
        uint256 _withdrawFeeFactor,
        uint256 _slippageFactor
    );

    event ResetAllowances();
    event Pause();
    event Unpause();
    event Panic();
    event SetGov(
      address _govAddress
    );


    modifier onlyGov() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

    function _vaultDeposit(uint256 _amount) internal virtual;
    function _vaultWithdraw(uint256 _amount) internal virtual;
    function earn() external virtual;
    function totalInUnderlying() public virtual view returns (uint256);
    function wantLockedTotal() public virtual view returns (uint256);
    function _resetAllowances() internal virtual;
    function _emergencyVaultWithdraw() internal virtual;

    function deposit(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant whenNotPaused returns (uint256) {
        // Call must happen before transfer
        uint256 wantLockedBefore = wantLockedTotal();

        IERC20(wantAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        // Proper deposit amount for tokens with fees, or vaults with deposit fees
        uint256 sharesAdded = _farm();
        if (sharesTotal > 0) {
            sharesAdded = sharesAdded.mul(sharesTotal).div(wantLockedBefore);
        }
        sharesTotal = sharesTotal.add(sharesAdded);

        return sharesAdded;
    }

    function _farm() internal returns (uint256) {
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (wantAmt == 0) return 0;

        uint256 sharesBefore = totalInUnderlying();
        _vaultDeposit(wantAmt);
        uint256 sharesAfter = totalInUnderlying();

        return sharesAfter.sub(sharesBefore);
    }

    function withdraw(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt is 0");

        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this)); // Check balance for wantAmt on strategy

        // Check if strategy has tokens from panic
        if (_wantAmt > wantAmt) {                                       // requested withdraw more than balance
            _vaultWithdraw(_wantAmt.sub(wantAmt));                      // withdraws all existing balance available (if panic, wantAmt = 0)
            wantAmt = IERC20(wantAddress).balanceOf(address(this));     // reset wantAmt value
        }

        if (_wantAmt > wantAmt) {                                       // conditional to set requested _wantAmt to balance of want tokens in contract
            _wantAmt = wantAmt;                                         // That way, user only withdraws what is allocated
        }

        if (_wantAmt > wantLockedTotal()) {                             // Final check!! wantLockedTotal() might not be the same as LP token balance
            _wantAmt = wantLockedTotal();
        }
        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal());
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);

        // Withdraw fee
        uint256 withdrawFee = _wantAmt // Want 100 tokens
            .mul(withdrawFeeFactorMax.sub(withdrawFeeFactor))  // 100 tokens * (10000 - 9990) = 10 * 10 = 1000
            .div(withdrawFeeFactorMax); // 1000 / 10000 = 0.1 tokens (withdrawal fees of 0.1%)
        if (withdrawFee > 0) {
            IERC20(wantAddress).safeTransfer(withdrawFeeAddress, withdrawFee);
        }

        _wantAmt = _wantAmt.sub(withdrawFee); // 100 tokens - 0.1 tokens = 99.9 tokens

        IERC20(wantAddress).safeTransfer(vaultChefAddress, _wantAmt);

        return sharesRemoved;
    }

    // To pay for earn function
    // To pay for other operating costs that will further grow our protocol
    function distributeFees(uint256 _earnedAmt) internal returns (uint256) {
        if (controllerFee > 0) {
            uint256 fee = _earnedAmt.mul(controllerFee).div(feeMax);

            _safeSwapWmatic(
                fee,
                earnedToWmaticPath,
                feeAddress
            );

            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    function distributeRewards(uint256 _earnedAmt) internal returns (uint256) {
        if (rewardRate > 0) {
            uint256 fee = _earnedAmt.mul(rewardRate).div(feeMax);

            uint256 usdcBefore = IERC20(usdcAddress).balanceOf(address(this));

            _safeSwap(
                fee,
                earnedToUsdcPath,
                address(this)
            );

            uint256 usdcAfter = IERC20(usdcAddress).balanceOf(address(this)).sub(usdcBefore);

            IStrategyTime(rewardAddress).depositReward(usdcAfter);

            _earnedAmt = _earnedAmt.sub(fee);
        }

        return _earnedAmt;
    }

    function buyBack(uint256 _earnedAmt) internal virtual returns (uint256) {
        if (buyBackRate > 0) {
            uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(feeMax);

            uint256 timeBefore = IERC20(timeAddress).balanceOf(address(this)); // Check TIME balance before swapping

            _safeSwap(
              buyBackAmt,
              earnedToTimePath,
              address(this) // Single swap buys back TIME to Strat address
            );

            uint256 timeAfter = IERC20(timeAddress).balanceOf(address(this)).sub(timeBefore); // Get TIME balance after swap

            _safeTimeTransfer(
              treasuryAddress,
              timeAfter.div(2) // Transfer 50% to treasuryAddress
            );

            _safeTimeTransfer(
              masterchefAddress,
              timeAfter.div(2) // Transfer 50% TIME to masterchefAddress
            );

            _earnedAmt = _earnedAmt.sub(buyBackAmt);
        }

        return _earnedAmt;
    }

    function resetAllowances() external onlyGov {
        _resetAllowances();

        emit ResetAllowances();
    }

    function pause() external onlyGov {
        _pause();

        emit Pause();
    }

    function unpause() external onlyGov {
        _unpause();
        _farm();

        emit Unpause();
    }

    function panic() external onlyGov {
        _pause();
        _emergencyVaultWithdraw();

        IERC20(wantAddress).safeApprove(uniRouterAddress, 0); // Revoke approval

        emit Panic();
    }

    function setGov(address _govAddress) external onlyGov {
        govAddress = _govAddress;

        emit SetGov(
          _govAddress
        );
    }

    function setSettings(
        uint256 _withdrawFeeFactor,
        uint256 _slippageFactor
    ) external onlyGov {
        require(_withdrawFeeFactor >= withdrawFeeFactorLL, "_withdrawFeeFactor too low");
        require(_withdrawFeeFactor <= withdrawFeeFactorMax, "_withdrawFeeFactor too high");
        require(_slippageFactor <= slippageFactorUL, "_slippageFactor too high");
        withdrawFeeFactor = _withdrawFeeFactor;
        slippageFactor = _slippageFactor;

        emit SetSettings(
            _withdrawFeeFactor,
            _slippageFactor
        );
    }

    function _safeSwap(
        uint256 _amountIn,
        address[] memory _path,
        address _to
    ) internal {
        uint256[] memory amounts = IUniRouter02(uniRouterAddress).getAmountsOut(_amountIn, _path);
        uint256 amountOut = amounts[amounts.length.sub(1)];

        if (_amountIn > 0) {
          IUniRouter02(uniRouterAddress).swapExactTokensForTokens(
              _amountIn,
              amountOut.mul(slippageFactor).div(1000),
              _path,
              _to,
              now
          );

        }
    }

    // Safe TIME transfer function, just in case if rounding error causes pool to not have enough TIME.
    function _safeTimeTransfer(address _to, uint256 _amount) internal {
        uint256 timeBal = IERC20(timeAddress).balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > timeBal) {
            transferSuccess = IERC20(timeAddress).transfer(_to, timeBal);
        } else {
            transferSuccess = IERC20(timeAddress).transfer(_to, _amount);
        }
        require(transferSuccess, "safeTimeTransfer: Transfer failed");
    }

    function _safeSwapWmatic(
        uint256 _amountIn,
        address[] memory _path,
        address _to
    ) internal {
        uint256[] memory amounts = IUniRouter02(uniRouterAddress).getAmountsOut(_amountIn, _path);
        uint256 amountOut = amounts[amounts.length.sub(1)];

        if (_amountIn > 0) {
          IUniRouter02(uniRouterAddress).swapExactTokensForETH(
              _amountIn,
              amountOut.mul(slippageFactor).div(1000),
              _path,
              _to,
              now
          );
        }
    }
}
