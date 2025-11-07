// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IIncentivePool {
    function distributeReward(
        address funderPayee,
        address foundation,
        address operatorPayee,
        uint256 foundationNativeRate,
        uint256 foundationGoatRate,
        uint256 operatorNativeRate,
        uint256 operatorGoatRate
    ) external;

    function withdrawCommissions(address owner, address to) external;

    function reassignCommission(address from, address to) external;
}
