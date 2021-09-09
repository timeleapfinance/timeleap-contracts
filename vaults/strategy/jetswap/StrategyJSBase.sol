// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libs/IMasterchef.sol";
import "../BaseStrategyLPSingle.sol";

contract StrategyJSBase is BaseStrategyLPSingle {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public stakingRewardsAddress;
    uint256 public pid;

    constructor(
        address _vaultChefAddress,
        address _stakingRewardsAddress, // Staking Rewards / MasterChef Address
        uint256 _pid, // Staking Rewards Pool ID
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
        stakingRewardsAddress = _stakingRewardsAddress; // JetSwap MasterChef

        uniRouterAddress = 0x5C6EC38fb0e2609672BDf628B1fD605A523E5923; // JetSwap UniRouter

        wantAddress = _wantAddress;
        token0Address = IUniPair(wantAddress).token0();
        token1Address = IUniPair(wantAddress).token1();

        pid = _pid;
        earnedAddress = _earnedAddress; // PWings Address

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
        IMasterchef(stakingRewardsAddress).deposit(pid, _amount);
    }

    function _vaultWithdraw(uint256 _amount) internal override {
        IMasterchef(stakingRewardsAddress).withdraw(pid, _amount);
    }

    function _vaultHarvest() internal override {
        IMasterchef(stakingRewardsAddress).withdraw(pid, 0);
    }

    function totalInUnderlying() public override view returns (uint256) {
        (uint256 amount,) = IMasterchef(stakingRewardsAddress).userInfo(pid, address(this));
        return amount;
    }

    function wantLockedTotal() public override view returns (uint256) {
        return IERC20(wantAddress).balanceOf(address(this))
            .add(totalInUnderlying());
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
        IMasterchef(stakingRewardsAddress).emergencyWithdraw(pid);
    }
}
