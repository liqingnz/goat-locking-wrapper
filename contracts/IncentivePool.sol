// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IIncentivePool} from "./interfaces/IIncentivePool.sol";

contract IncentivePool is Ownable, IIncentivePool {
    uint256 public constant MAX_COMMISSION_RATE = 10000; // 100%

    IERC20 public immutable rewardToken;

    mapping(address token => uint256 amount) public commissions;

    event RewardDistributed(
        address payee,
        address token,
        uint256 reward,
        uint256 commission
    );

    event CommissionWithdrawn(address to, address token, uint256 amount);

    constructor(IERC20 _rewardToken) Ownable(msg.sender) {
        rewardToken = _rewardToken;
    }

    function distributeReward(
        uint256 commissionRate,
        uint256 goatCommissionRate,
        address rewardPayee
    ) external override onlyOwner {
        require(
            commissionRate <= MAX_COMMISSION_RATE,
            "Invalid commission rate"
        );
        require(rewardPayee != address(0), "Invalid reward payee address");

        // Handle native currency reward
        {
            uint256 remain = address(this).balance - commissions[address(0)];
            if (remain > 0) {
                uint256 commission = (remain * commissionRate) /
                    MAX_COMMISSION_RATE;
                commissions[address(0)] += commission;

                uint256 reward = remain - commission;
                if (reward > 0) {
                    (bool successReward, ) = rewardPayee.call{value: reward}(
                        ""
                    );
                    require(successReward, "Reward transfer failed");
                }

                emit RewardDistributed(
                    rewardPayee,
                    address(0),
                    reward,
                    commission
                );
            }
        }

        // Handle ERC20 reward token
        {
            uint256 tokenRemain = rewardToken.balanceOf(address(this)) -
                commissions[address(rewardToken)];
            if (tokenRemain > 0) {
                uint256 tokenCommission = (tokenRemain * goatCommissionRate) /
                    MAX_COMMISSION_RATE;
                commissions[address(rewardToken)] += tokenCommission;

                uint256 tokenReward = tokenRemain - tokenCommission;
                if (tokenReward > 0) {
                    require(
                        rewardToken.transfer(rewardPayee, tokenReward),
                        "Token reward transfer failed"
                    );
                }

                emit RewardDistributed(
                    rewardPayee,
                    address(rewardToken),
                    tokenReward,
                    tokenCommission
                );
            }
        }
    }

    function withdrawCommissions(address to) external override onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 amount = commissions[address(0)];
        if (amount > 0) {
            commissions[address(0)] = 0;
            (bool success, ) = to.call{value: amount}("");
            require(success, "Commission transfer failed");
            emit CommissionWithdrawn(to, address(0), amount);
        }

        uint256 tokenAmount = commissions[address(rewardToken)];
        if (tokenAmount > 0) {
            commissions[address(rewardToken)] = 0;
            require(
                rewardToken.transfer(to, tokenAmount),
                "Token commission transfer failed"
            );
            emit CommissionWithdrawn(to, address(rewardToken), tokenAmount);
        }
    }
}
