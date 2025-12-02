// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IIncentivePool} from "./interfaces/IIncentivePool.sol";

contract IncentivePool is Ownable, ReentrancyGuard, IIncentivePool {
    uint256 public constant MAX_COMMISSION_RATE = 10000; // 100%

    IERC20 public immutable rewardToken;

    uint256 public foundationNativeCommission;
    uint256 public operatorNativeCommission;
    uint256 public foundationTokenCommission;
    uint256 public operatorTokenCommission;
    uint256 public totalNativeCommission;
    uint256 public totalTokenCommission;

    uint256 public operatorNativeAllowance;
    uint256 public operatorTokenAllowance;
    uint256 public operatorNativeAllowanceUsed;
    uint256 public operatorTokenAllowanceUsed;
    uint256 public allowanceUpdatePeriod;
    uint256 public allowanceClearTimestamp;

    event OperatorAllowanceConfigured(
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 updatePeriod,
        uint256 nextResetTimestamp
    );

    event RewardDistributed(
        address indexed payee,
        address indexed token,
        uint256 reward,
        uint256 totalCommission
    );

    event CommissionAccrued(
        address indexed owner,
        address indexed token,
        uint256 amount
    );

    event FoundationCommissionWithdrawn(
        address indexed to,
        address indexed token,
        uint256 amount
    );

    event OperatorCommissionWithdrawn(
        address indexed to,
        address indexed token,
        uint256 amount
    );

    constructor(
        IERC20 _rewardToken,
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 updatePeriod
    ) Ownable(msg.sender) {
        rewardToken = _rewardToken;
        _setOperatorAllowanceConfig(
            nativeAllowance,
            tokenAllowance,
            updatePeriod
        );
    }

    receive() external payable {}

    function distributeReward(
        address funderPayee,
        address foundation,
        address operatorPayee,
        uint256 foundationNativeRate,
        uint256 foundationGoatRate,
        uint256 operatorNativeRate,
        uint256 operatorGoatRate
    ) external override onlyOwner {
        require(funderPayee != address(0), "Invalid funder payee");
        require(foundation != address(0), "Invalid foundation");
        require(operatorPayee != address(0), "Invalid operator payee");
        require(
            foundationNativeRate + operatorNativeRate <= MAX_COMMISSION_RATE,
            "Native rate overflow"
        );
        require(
            foundationGoatRate + operatorGoatRate <= MAX_COMMISSION_RATE,
            "Goat rate overflow"
        );

        _refreshOperatorAllowance();

        // Handle native currency reward
        uint256 nativeAvailable = address(this).balance - totalNativeCommission;
        if (nativeAvailable > 0) {
            uint256 foundationShare = (nativeAvailable * foundationNativeRate) /
                MAX_COMMISSION_RATE;
            uint256 operatorShare = (nativeAvailable * operatorNativeRate) /
                MAX_COMMISSION_RATE;
            operatorShare = _applyOperatorAllowance(operatorShare, true);
            uint256 totalCommission = foundationShare + operatorShare;

            if (foundationShare > 0) {
                foundationNativeCommission += foundationShare;
                totalNativeCommission += foundationShare;
                emit CommissionAccrued(foundation, address(0), foundationShare);
            }
            if (operatorShare > 0) {
                operatorNativeCommission += operatorShare;
                totalNativeCommission += operatorShare;
                emit CommissionAccrued(
                    operatorPayee,
                    address(0),
                    operatorShare
                );
            }

            uint256 payout = nativeAvailable - totalCommission;
            if (payout > 0) {
                (bool success, ) = funderPayee.call{value: payout}("");
                require(success, "Reward transfer failed");
            }

            emit RewardDistributed(
                funderPayee,
                address(0),
                payout,
                totalCommission
            );
        }

        // Handle ERC20 reward token
        uint256 tokenAvailable = rewardToken.balanceOf(address(this)) -
            totalTokenCommission;
        if (tokenAvailable > 0) {
            uint256 foundationTokenShare = (tokenAvailable *
                foundationGoatRate) / MAX_COMMISSION_RATE;
            uint256 operatorTokenShare = (tokenAvailable * operatorGoatRate) /
                MAX_COMMISSION_RATE;
            operatorTokenShare = _applyOperatorAllowance(
                operatorTokenShare,
                false
            );
            uint256 totalTokensCommission = foundationTokenShare +
                operatorTokenShare;

            if (foundationTokenShare > 0) {
                foundationTokenCommission += foundationTokenShare;
                totalTokenCommission += foundationTokenShare;
                emit CommissionAccrued(
                    foundation,
                    address(rewardToken),
                    foundationTokenShare
                );
            }
            if (operatorTokenShare > 0) {
                operatorTokenCommission += operatorTokenShare;
                totalTokenCommission += operatorTokenShare;
                emit CommissionAccrued(
                    operatorPayee,
                    address(rewardToken),
                    operatorTokenShare
                );
            }

            uint256 tokenPayout = tokenAvailable - totalTokensCommission;
            if (tokenPayout > 0) {
                require(
                    rewardToken.transfer(funderPayee, tokenPayout),
                    "Token reward transfer failed"
                );
            }

            emit RewardDistributed(
                funderPayee,
                address(rewardToken),
                tokenPayout,
                totalTokensCommission
            );
        }
    }

    function withdrawFoundationCommission(
        address to
    ) external override onlyOwner nonReentrant {
        require(to != address(0), "Invalid address");

        uint256 nativeAmount = foundationNativeCommission;
        if (nativeAmount > 0) {
            foundationNativeCommission = 0;
            totalNativeCommission -= nativeAmount;
            (bool successNative, ) = to.call{value: nativeAmount}("");
            require(successNative, "Commission transfer failed");
            emit FoundationCommissionWithdrawn(to, address(0), nativeAmount);
        }

        uint256 tokenAmount = foundationTokenCommission;
        if (tokenAmount > 0) {
            foundationTokenCommission = 0;
            totalTokenCommission -= tokenAmount;
            require(
                rewardToken.transfer(to, tokenAmount),
                "Token commission transfer failed"
            );
            emit FoundationCommissionWithdrawn(
                to,
                address(rewardToken),
                tokenAmount
            );
        }
    }

    function withdrawOperatorCommission(
        address to
    ) external override onlyOwner nonReentrant {
        require(to != address(0), "Invalid address");

        uint256 nativeAmount = operatorNativeCommission;
        if (nativeAmount > 0) {
            operatorNativeCommission = 0;
            totalNativeCommission -= nativeAmount;
            (bool successNative, ) = to.call{value: nativeAmount}("");
            require(successNative, "Commission transfer failed");
            emit OperatorCommissionWithdrawn(to, address(0), nativeAmount);
        }

        uint256 tokenAmount = operatorTokenCommission;
        if (tokenAmount > 0) {
            operatorTokenCommission = 0;
            totalTokenCommission -= tokenAmount;
            require(
                rewardToken.transfer(to, tokenAmount),
                "Token commission transfer failed"
            );
            emit OperatorCommissionWithdrawn(
                to,
                address(rewardToken),
                tokenAmount
            );
        }
    }

    function getOperatorAllowanceConfig()
        external
        view
        returns (
            uint256 nativeAllowance,
            uint256 tokenAllowance,
            uint256 updatePeriod,
            uint256 nextResetTimestamp
        )
    {
        return (
            operatorNativeAllowance,
            operatorTokenAllowance,
            allowanceUpdatePeriod,
            allowanceClearTimestamp
        );
    }

    function setOperatorAllowanceConfig(
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 updatePeriod
    ) external onlyOwner {
        _setOperatorAllowanceConfig(
            nativeAllowance,
            tokenAllowance,
            updatePeriod
        );

        emit OperatorAllowanceConfigured(
            nativeAllowance,
            tokenAllowance,
            updatePeriod,
            allowanceClearTimestamp
        );
    }

    function _refreshOperatorAllowance() internal {
        uint256 period = allowanceUpdatePeriod;
        uint256 nextReset = allowanceClearTimestamp;

        if (period == 0 || nextReset == 0 || block.timestamp < nextReset) {
            return;
        }

        uint256 intervals = 1 + (block.timestamp - nextReset) / period;
        operatorNativeAllowanceUsed = 0;
        operatorTokenAllowanceUsed = 0;
        allowanceClearTimestamp = nextReset + (intervals * period);
    }

    function _setOperatorAllowanceConfig(
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 updatePeriod
    ) internal {
        operatorNativeAllowance = nativeAllowance;
        operatorTokenAllowance = tokenAllowance;
        allowanceUpdatePeriod = updatePeriod;
        operatorNativeAllowanceUsed = 0;
        operatorTokenAllowanceUsed = 0;
        allowanceClearTimestamp = updatePeriod == 0
            ? block.timestamp
            : block.timestamp + updatePeriod;
    }

    function _applyOperatorAllowance(
        uint256 amount,
        bool isNative
    ) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        uint256 cap = isNative
            ? operatorNativeAllowance
            : operatorTokenAllowance;
        if (cap == 0) {
            return amount;
        }

        uint256 used = isNative
            ? operatorNativeAllowanceUsed
            : operatorTokenAllowanceUsed;

        if (used >= cap) {
            return 0;
        }

        uint256 remaining = cap - used;
        uint256 permitted = amount > remaining ? remaining : amount;

        if (isNative) {
            operatorNativeAllowanceUsed = used + permitted;
        } else {
            operatorTokenAllowanceUsed = used + permitted;
        }

        return permitted;
    }
}
