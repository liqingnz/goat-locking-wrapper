// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IIncentivePool {
    function distributeReward(
        uint256 commissionRate,
        uint256 goatCommissionRate,
        address rewardPayee
    ) external;

    function withdrawCommissions(address to) external;
}
