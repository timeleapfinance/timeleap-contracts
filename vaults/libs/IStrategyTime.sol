// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IStrategyTime {
    function depositReward(uint256 _depositAmt) external returns (bool);
}
