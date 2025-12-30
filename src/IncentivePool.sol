// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IIncentivePool} from "./interfaces/IIncentivePool.sol";

/**
 * @title IncentivePool
 * @notice Holds pending rewards for a single validator and enforces commission
 * splits plus operator allowance caps before paying the funder.
 * @dev Each pool is owned by a `ValidatorEntry*` contract which controls
 * distribution, withdrawals, and allowance configuration on behalf of the
 * validator.
 */
contract IncentivePool is Ownable, ReentrancyGuard, IIncentivePool {
    uint256 public constant MAX_COMMISSION_RATE = 10000; // 100%

    IERC20 public immutable rewardToken;

    uint256 public foundationNativeCommission;
    uint256 public operatorNativeCommission;
    uint256 public foundationTokenCommission;
    uint256 public operatorTokenCommission;
    uint256 public totalNativeCommission;
    uint256 public totalTokenCommission;
    uint256 public funderNativeAccrued;

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
        uint256 foundationCommission,
        uint256 operatorCommission,
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

    /// @notice Constructs a pool tied to a specific validator/reward token pair.
    /// @param _rewardToken ERC20 token used as the incentive currency.
    /// @param nativeAllowance Operator cap for native commissions per period.
    /// @param tokenAllowance Operator cap for token commissions per period.
    /// @param updatePeriod Duration of an allowance window.
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

    /// @notice Accepts native rewards from the locking contract.
    receive() external payable {}

    /// @notice Splits pool balances into commissions and funder payouts.
    /// @param funderPayee Recipient of the net reward.
    /// @param foundation Foundation commission owner.
    /// @param operatorPayee Operator commission owner.
    /// @param foundationNativeRate Foundation share of native rewards (bps).
    /// @param foundationGoatRate Foundation share of token rewards (bps).
    /// @param operatorNativeRate Operator share of native rewards (bps).
    /// @param operatorGoatRate Operator share of token rewards (bps).
    function distributeReward(
        address funderPayee,
        address foundation,
        address operatorPayee,
        uint256 foundationNativeRate,
        uint256 foundationGoatRate,
        uint256 operatorNativeRate,
        uint256 operatorGoatRate
    ) external override onlyOwner nonReentrant {
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
        uint256 nativeAvailable = address(this).balance -
            totalNativeCommission -
            funderNativeAccrued;
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
            }
            emit CommissionAccrued(foundation, address(0), foundationShare);
            if (operatorShare > 0) {
                operatorNativeCommission += operatorShare;
                totalNativeCommission += operatorShare;
            }
            emit CommissionAccrued(operatorPayee, address(0), operatorShare);

            funderNativeAccrued += nativeAvailable - totalCommission;
            if (funderNativeAccrued > 0) {
                (bool success, ) = funderPayee.call{value: funderNativeAccrued}(
                    ""
                );
                if (success) {
                    funderNativeAccrued = 0;
                }
            }

            emit RewardDistributed(
                funderPayee,
                address(0),
                funderNativeAccrued,
                foundationShare,
                operatorShare,
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
            }
            emit CommissionAccrued(
                foundation,
                address(rewardToken),
                foundationTokenShare
            );
            if (operatorTokenShare > 0) {
                operatorTokenCommission += operatorTokenShare;
                totalTokenCommission += operatorTokenShare;
            }
            emit CommissionAccrued(
                operatorPayee,
                address(rewardToken),
                operatorTokenShare
            );

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
                foundationTokenShare,
                operatorTokenShare,
                totalTokensCommission
            );
        }
    }

    /// @notice Sends the accumulated foundation commissions to a wallet.
    /// @param to Destination wallet for both native and token commissions.
    function withdrawFoundationCommission(
        address to
    ) external override onlyOwner nonReentrant {
        require(to != address(0), "Invalid address");

        uint256 nativeAmount = foundationNativeCommission;
        if (nativeAmount > 0) {
            foundationNativeCommission = 0;
            totalNativeCommission -= nativeAmount;
            to.call{value: nativeAmount}("");
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

    /// @notice Sends the accumulated operator commissions to a wallet.
    /// @param to Destination wallet for both native and token commissions.
    function withdrawOperatorCommission(
        address to
    ) external override onlyOwner nonReentrant {
        require(to != address(0), "Invalid address");

        uint256 nativeAmount = operatorNativeCommission;
        if (nativeAmount > 0) {
            operatorNativeCommission = 0;
            totalNativeCommission -= nativeAmount;
            to.call{value: nativeAmount}("");
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

    /// @notice Returns the current operator allowance settings.
    /// @return nativeAllowance Cap for native commissions within a period.
    /// @return tokenAllowance Cap for token commissions within a period.
    /// @return updatePeriod Duration of each allowance period.
    /// @return nextResetTimestamp Timestamp when allowances reset next.
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

    /// @notice Updates allowance caps and emits the resulting schedule.
    /// @param nativeAllowance Cap for native commissions per period.
    /// @param tokenAllowance Cap for token commissions per period.
    /// @param updatePeriod Duration of each allowance period.
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
    }

    /// @dev Resets operator allowance tracking if the period elapsed.
    function _refreshOperatorAllowance() internal {
        uint256 period = allowanceUpdatePeriod;
        uint256 nextReset = allowanceClearTimestamp;

        if (period == 0 || block.timestamp < nextReset) {
            return;
        }

        uint256 intervals = 1 + (block.timestamp - nextReset) / period;
        operatorNativeAllowanceUsed = 0;
        operatorTokenAllowanceUsed = 0;
        allowanceClearTimestamp = nextReset + (intervals * period);
    }

    /// @dev Applies new allowance parameters and resets usage counters.
    /// @param nativeAllowance Cap for native commissions.
    /// @param tokenAllowance Cap for token commissions.
    /// @param updatePeriod Duration of allowance windows.
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

        emit OperatorAllowanceConfigured(
            nativeAllowance,
            tokenAllowance,
            updatePeriod,
            allowanceClearTimestamp
        );
    }

    /// @dev Clamps operator commission amounts to the configured allowance.
    /// @param amount Requested commission amount.
    /// @param isNative True if the commission is native currency.
    /// @return permitted The portion allowed under the cap.
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
