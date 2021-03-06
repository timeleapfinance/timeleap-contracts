// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libs/IQuickStake.sol";
import "../BaseStrategyLPSingle.sol";

pragma solidity 0.6.12;

contract StrategyQuickSwapWmaticWeth is BaseStrategyLPSingle {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public stakingRewardsAddress;

    constructor(
        address _vaultChefAddress,
        address _stakingRewardsAddress, // QuickSwap Staking Rewards
        address _wantAddress,
        address _earnedAddress,
        address[] memory _earnedToWmaticPath,
        address[] memory _earnedToUsdcPath,
        address[] memory _earnedToTimePath,
        address[] memory _earnedToToken0Path,
        address[] memory _earnedToToken1Path,
        address[] memory _token0ToEarnedPath,
        address[] memory _token1ToEarnedPath
    ) public {
        require(address(_wantAddress) != address(_earnedAddress), "wantAddress and earnedAddress cannot be the same"); // Added sanity check for _wantAddress vs _earnedAddress
        govAddress = msg.sender;
        vaultChefAddress = _vaultChefAddress;

        wantAddress = _wantAddress;
        token0Address = IUniPair(wantAddress).token0();
        token1Address = IUniPair(wantAddress).token1();

        uniRouterAddress = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff; // QuickSwap UniRouter
        stakingRewardsAddress = _stakingRewardsAddress;
        earnedAddress = _earnedAddress;

        earnedToWmaticPath = _earnedToWmaticPath;
        earnedToUsdcPath = _earnedToUsdcPath;
        earnedToTimePath = _earnedToTimePath;
        earnedToToken0Path = _earnedToToken0Path;
        earnedToToken1Path = _earnedToToken1Path;
        token0ToEarnedPath = _token0ToEarnedPath;
        token1ToEarnedPath = _token1ToEarnedPath;

        transferOwnership(vaultChefAddress);

        _resetAllowances();
    }

    function _vaultDeposit(uint256 _amount) internal override {
        IQuickStake(stakingRewardsAddress).stake(_amount);
    }

    function _vaultWithdraw(uint256 _amount) internal override {
        IQuickStake(stakingRewardsAddress).withdraw(_amount);
    }

    function _vaultHarvest() internal override {
        IQuickStake(stakingRewardsAddress).getReward();
    }

    function totalInUnderlying() public override view returns (uint256) {
        return IQuickStake(stakingRewardsAddress).balanceOf(address(this));
    }

    function wantLockedTotal() public override view returns (uint256) {
        return IERC20(wantAddress).balanceOf(address(this))
            .add(IQuickStake(stakingRewardsAddress).balanceOf(address(this)));
    }

    function _resetAllowances() internal override {
        IERC20(wantAddress).safeApprove(stakingRewardsAddress, uint256(0));
        IERC20(wantAddress).safeIncreaseAllowance(
            stakingRewardsAddress,
            uint256(-1)
        );

        IERC20(earnedAddress).safeApprove(uniRouterAddress, uint256(0));
        IERC20(earnedAddress).safeIncreaseAllowance(
            uniRouterAddress,
            uint256(-1)
        );

        IERC20(token0Address).safeApprove(uniRouterAddress, uint256(0));
        IERC20(token0Address).safeIncreaseAllowance(
            uniRouterAddress,
            uint256(-1)
        );

        IERC20(token1Address).safeApprove(uniRouterAddress, uint256(0));
        IERC20(token1Address).safeIncreaseAllowance(
            uniRouterAddress,
            uint256(-1)
        );

        IERC20(usdcAddress).safeApprove(rewardAddress, uint256(0));
        IERC20(usdcAddress).safeIncreaseAllowance(
            rewardAddress,
            uint256(-1)
        );
    }

    function _emergencyVaultWithdraw() internal override {
        IQuickStake(stakingRewardsAddress).withdraw(totalInUnderlying());
    }
}
