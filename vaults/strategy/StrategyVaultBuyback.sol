// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/Pausable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "../libs/IDragonLair.sol";
import "../libs/IQuickStake.sol";
import "../libs/IUniPair.sol";
import "../libs/IUniRouter02.sol";

contract StrategyVaultBurn is Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public quickSwapAddress;
    address public constant dragonLairAddress = 0xf28164A485B0B2C90639E47b0f377b4a438a16B1; // QuickSwap DragonLair Contract
    address public wantAddress;

    address public constant uniRouterAddress = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff; // QuickSwap Router
    address public constant dQuickAddress = 0xf28164A485B0B2C90639E47b0f377b4a438a16B1; // QuickSwap dQUICK token contract
    address public constant quickAddress = 0x831753DD7087CaC61aB5644b308642cc1c33Dc13; // QuickSwap QUICK token contract
    address public constant wmaticAddress = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; // WMATIC token contract
    address public constant timeAddress = 0x5c59D7Cb794471a9633391c4927ADe06B8787a90; // TIME token contract
    address public vaultChefAddress;
    address public govAddress;

    uint256 public buybackCycle = 6 hours;
    uint256 public lastEarnBlock = block.timestamp;
    uint256 public sharesTotal = 0;

    address public constant treasuryAddress = 0x52e4cf8B72bd0EE362666fc578dB916f20860bBf; // Treasury Wallet Address
    address public constant masterchefAddress = 0x41C4dFA389e8c43BA6220aa62021ed246d441306; // TIME MasterChef contract

    uint256 public slippageFactor = 950; // 5% default slippage tolerance
    uint256 public constant slippageFactorUL = 995;

    address[] public quickToTimePath;

    constructor(
        address _vaultChefAddress,
        address _quickSwapAddress,
        address _wantAddress
    ) public {
        govAddress = msg.sender;
        vaultChefAddress = _vaultChefAddress;
        wantAddress = _wantAddress;
        quickSwapAddress = _quickSwapAddress;
        quickToTimePath = [quickAddress, wmaticAddress, timeAddress];

        transferOwnership(vaultChefAddress);

        _resetAllowances();
    }

    event SetSettings(uint256 _slippageFactor,uint256 _buybackCycle);
    event Earn();
    event ResetAllowances();
    event Panic();
    event SetGov(address _govAddress);

    modifier onlyGov() {
        require(msg.sender == govAddress, "!gov");
        _;
    }

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

        uint256 sharesBefore = vaultSharesTotal();
        IQuickStake(quickSwapAddress).stake(wantAmt);
        uint256 sharesAfter = vaultSharesTotal();

        return sharesAfter.sub(sharesBefore);
    }

    function withdraw(address _userAddress, uint256 _wantAmt) external onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt is 0");

        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));

        // Check if strategy has tokens from panic
        if (_wantAmt > wantAmt) {
            IQuickStake(quickSwapAddress).withdraw(_wantAmt.sub(wantAmt));
            wantAmt = IERC20(wantAddress).balanceOf(address(this));
        }

        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (_wantAmt > wantLockedTotal()) {
            _wantAmt = wantLockedTotal();
        }

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal());
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);

        IERC20(wantAddress).safeTransfer(vaultChefAddress, _wantAmt);

        return sharesRemoved;
    }

    function earn() external nonReentrant whenNotPaused onlyGov {
        if (block.timestamp > lastEarnBlock.add(buybackCycle)) {
            buyBack();
        } else {
            lair();
        }
        emit Earn();
    }

    function lair() internal {
        IQuickStake(quickSwapAddress).getReward();

        uint256 earnedAmt = IERC20(quickAddress).balanceOf(address(this));
        if (earnedAmt > 0) {
            IDragonLair(dragonLairAddress).enter(earnedAmt);
        }
    }

    function buyBack() internal {
        uint256 lairBalance = IERC20(dQuickAddress).balanceOf(address(this));
        if (lairBalance > 0) {
            IDragonLair(dragonLairAddress).leave(lairBalance);

            uint256 earnedAmt = IERC20(quickAddress).balanceOf(address(this));


            if (earnedAmt > 0) {
                uint256 timeBefore = IERC20(timeAddress).balanceOf(address(this)); // Check TIME balance before swapping

                _safeSwap(
                  earnedAmt,
                  quickToTimePath,
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
            }
        }

        lastEarnBlock = block.timestamp;
    }

    // Emergency!!
    function pause() external onlyGov {
        _pause();
    }

    // False alarm
    function unpause() external onlyGov {
        _unpause();
        _farm();
    }

    function vaultSharesTotal() public view returns (uint256) {
        return IQuickStake(quickSwapAddress).balanceOf(address(this));
    }

    function wantLockedTotal() public view returns (uint256) {
        return IERC20(wantAddress).balanceOf(address(this))
            .add(IQuickStake(quickSwapAddress).balanceOf(address(this)));
    }

    function _resetAllowances() internal {
        IERC20(wantAddress).safeApprove(quickSwapAddress, uint256(0));
        IERC20(wantAddress).safeIncreaseAllowance(
            quickSwapAddress,
            uint256(-1)
        );

        IERC20(quickAddress).safeApprove(dragonLairAddress, uint256(0));
        IERC20(quickAddress).safeIncreaseAllowance(
            dragonLairAddress,
            uint256(-1)
        );

        IERC20(quickAddress).safeApprove(uniRouterAddress, uint256(0));
        IERC20(quickAddress).safeIncreaseAllowance(
            uniRouterAddress,
            uint256(-1)
        );
    }

    function resetAllowances() external onlyGov {
        _resetAllowances();
        emit ResetAllowances();
    }

    function panic() external onlyGov {
        _pause();
        IQuickStake(quickSwapAddress).withdraw(vaultSharesTotal());
        IERC20(wantAddress).safeDecreaseAllowance(
            uniRouterAddress,
            uint256(0)
        );

        emit Panic();
    }

    function setSettings(uint256 _slippageFactor,uint256 _buybackCycle) external onlyGov {
        require(_slippageFactor <= slippageFactorUL, "_slippageFactor too high");
        slippageFactor = _slippageFactor;
        buybackCycle = _buybackCycle;

        emit SetSettings(_slippageFactor,_buybackCycle);
    }

    function setGov(address _govAddress) external onlyGov {
        govAddress = _govAddress;
        emit SetGov(_govAddress);
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
}
