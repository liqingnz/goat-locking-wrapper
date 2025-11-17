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

    mapping(address owner => uint256 amount) public nativeCommissions;
    mapping(address owner => uint256 amount) public tokenCommissions;
    uint256 public totalNativeCommission;
    uint256 public totalTokenCommission;

    address public operator;
    uint256 public operatorNativeAllowance;
    uint256 public operatorTokenAllowance;
    uint256 public operatorNativeAllowanceUsed;
    uint256 public operatorTokenAllowanceUsed;
    uint256 public allowanceUpdatePeriod;
    uint256 public allowanceClearTimestamp;

    event OperatorAllowanceConfigured(
        address indexed operator,
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

    event CommissionWithdrawn(
        address indexed owner,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    event CommissionReassigned(
        address indexed from,
        address indexed to,
        uint256 nativeAmount,
        uint256 tokenAmount
    );

    constructor(
        IERC20 _rewardToken,
        address initialOperator,
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 updatePeriod
    ) Ownable(msg.sender) {
        rewardToken = _rewardToken;
        _setOperatorAllowanceConfig(
            initialOperator,
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
            operatorShare = _applyOperatorAllowance(
                operatorPayee,
                operatorShare,
                true
            );
            uint256 totalCommission = foundationShare + operatorShare;

            if (foundationShare > 0) {
                nativeCommissions[foundation] += foundationShare;
                totalNativeCommission += foundationShare;
                emit CommissionAccrued(foundation, address(0), foundationShare);
            }
            if (operatorShare > 0) {
                nativeCommissions[operatorPayee] += operatorShare;
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
                operatorPayee,
                operatorTokenShare,
                false
            );
            uint256 totalTokensCommission = foundationTokenShare +
                operatorTokenShare;

            if (foundationTokenShare > 0) {
                tokenCommissions[foundation] += foundationTokenShare;
                totalTokenCommission += foundationTokenShare;
                emit CommissionAccrued(
                    foundation,
                    address(rewardToken),
                    foundationTokenShare
                );
            }
            if (operatorTokenShare > 0) {
                tokenCommissions[operatorPayee] += operatorTokenShare;
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

    function withdrawCommissions(
        address owner,
        address to
    ) external override onlyOwner nonReentrant {
        require(owner != address(0), "Invalid owner");
        require(to != address(0), "Invalid address");

        uint256 nativeAmount = nativeCommissions[owner];
        if (nativeAmount > 0) {
            nativeCommissions[owner] = 0;
            totalNativeCommission -= nativeAmount;
            (bool successNative, ) = to.call{value: nativeAmount}("");
            require(successNative, "Commission transfer failed");
            emit CommissionWithdrawn(owner, to, address(0), nativeAmount);
        }

        uint256 tokenAmount = tokenCommissions[owner];
        if (tokenAmount > 0) {
            tokenCommissions[owner] = 0;
            totalTokenCommission -= tokenAmount;
            require(
                rewardToken.transfer(to, tokenAmount),
                "Token commission transfer failed"
            );
            emit CommissionWithdrawn(
                owner,
                to,
                address(rewardToken),
                tokenAmount
            );
        }
    }

    function reassignCommission(
        address from,
        address to
    ) external override onlyOwner {
        require(from != address(0), "Invalid from");
        require(to != address(0), "Invalid to");
        if (from == to) {
            return;
        }

        uint256 nativeAmount = nativeCommissions[from];
        if (nativeAmount > 0) {
            nativeCommissions[from] = 0;
            nativeCommissions[to] += nativeAmount;
        }

        uint256 tokenAmount = tokenCommissions[from];
        if (tokenAmount > 0) {
            tokenCommissions[from] = 0;
            tokenCommissions[to] += tokenAmount;
        }

        if (nativeAmount > 0 || tokenAmount > 0) {
            emit CommissionReassigned(from, to, nativeAmount, tokenAmount);
        }
    }

    function getOperatorAllowanceConfig()
        external
        view
        returns (
            address operatorAddress,
            uint256 nativeAllowance,
            uint256 tokenAllowance,
            uint256 updatePeriod,
            uint256 nextResetTimestamp
        )
    {
        return (
            operator,
            operatorNativeAllowance,
            operatorTokenAllowance,
            allowanceUpdatePeriod,
            allowanceClearTimestamp
        );
    }

    function setOperatorAllowanceConfig(
        address newOperator,
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 updatePeriod
    ) external onlyOwner {
        _setOperatorAllowanceConfig(
            newOperator,
            nativeAllowance,
            tokenAllowance,
            updatePeriod
        );

        emit OperatorAllowanceConfigured(
            newOperator,
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
        address newOperator,
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 updatePeriod
    ) internal {
        operator = newOperator;
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
        address operatorPayee,
        uint256 amount,
        bool isNative
    ) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        if (operator == address(0) || operatorPayee != operator) {
            return amount;
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
