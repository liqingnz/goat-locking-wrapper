// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILocking} from "./interfaces/IGoatLocking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IncentivePool} from "./IncentivePool.sol";

contract ValidatorEntry {
    // the underlying staking contract address
    ILocking public immutable underlying;
    IERC20 public immutable rewardToken;

    mapping(address validator => ValidatorInfo info) validators;

    event ValidatorMigrated(
        address validator,
        address owner,
        address incentivePool,
        address rewardPayee,
        address funder,
        uint256 commissionRate,
        uint256 goatCommissionRate
    );

    event ValidatorCommissionRateUpdated(
        address validator,
        uint256 commissionRate,
        uint256 goatCommissionRate
    );

    event ValidatorRewardPayeeUpdated(address validator, address rewardPayee);

    struct ValidatorInfo {
        address owner; // the owner of the validator in this contract
        address incentivePool; // the incentive pool address for receiving rewards
        address rewardPayee; // the address who receives the rewards in the incentive pool
        address funder; // the address who funded the validator locking
        uint256 commissionRate; // the commission rate in basis points (1e4 = 100%)
        uint256 goatCommissionRate; // the commission rate for GOAT token in basis points (1e4 = 100%)
    }

    constructor(ILocking _underlying, IERC20 _rewardToken) {
        underlying = _underlying;
        rewardToken = _rewardToken;
    }

    // migrate a validator to this contract
    // You must call this function with the changeValidatorOwner call in the same transaction
    function migrate(
        address validator,
        address owner,
        address rewardPayee,
        address funder,
        uint256 commissionRate,
        uint256 goatCommissionRate
    ) external {
        require(address(this) == underlying.owners(validator), "Not the owner");
        require(
            address(validators[validator].incentivePool) == address(0),
            "Already migrated"
        );
        require(owner != address(0), "Invalid owner address");
        require(rewardPayee != address(0), "Invalid reward payee address");
        require(funder != address(0), "Invalid funder address");
        require(commissionRate <= 1e4, "Invalid commission rate");
        validators[validator] = ValidatorInfo({
            owner: owner,
            incentivePool: address(new IncentivePool(rewardToken)),
            rewardPayee: rewardPayee,
            funder: funder,
            commissionRate: commissionRate,
            goatCommissionRate: goatCommissionRate
        });
        emit ValidatorMigrated(
            validator,
            owner,
            validators[validator].incentivePool,
            rewardPayee,
            funder,
            commissionRate,
            goatCommissionRate
        );
    }

    // migrate from this contract to another one and cleanup the incentive pool
    function migrateTo(address validator, address newOwner) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.owner, "Not the owner");
        IncentivePool(info.incentivePool).distributeReward(
            info.commissionRate,
            info.goatCommissionRate,
            info.rewardPayee
        );
        IncentivePool(info.incentivePool).withdrawCommissions(info.owner);
        underlying.changeValidatorOwner(validator, newOwner);
        delete validators[validator];
    }

    // set commission rate for a validator, you must be the owner
    function setCommissionRate(
        address validator,
        uint256 commissionRate,
        uint256 goatCommissionRate
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.owner, "Not the owner");
        require(commissionRate <= 1e4, "Invalid commission rate");
        info.commissionRate = commissionRate;
        info.goatCommissionRate = goatCommissionRate;
        emit ValidatorCommissionRateUpdated(
            validator,
            commissionRate,
            goatCommissionRate
        );
    }

    // set reward payee for a validator, you must be the funder
    function setRewardPayee(address validator, address rewardPayee) external {
        ValidatorInfo storage info = validators[validator];
        // allow funder to change reward payee
        require(msg.sender == info.funder, "Not the funder");
        require(rewardPayee != address(0), "Invalid reward payee address");
        info.rewardPayee = rewardPayee;
        emit ValidatorRewardPayeeUpdated(validator, rewardPayee);
    }

    // withdraw commissions for a validator
    function withdrawCommissions(address validator, address to) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.owner, "Not the owner");
        IncentivePool(info.incentivePool).withdrawCommissions(to); // it checks if the address is valid
    }

    // claim rewards for a validator from underlying staking contract and distribute them
    function claimRewards(address validator) external {
        // anyone can call this function to claim rewards for a validator
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != (address(0)), "Not migrated");
        // the claim operation is asynchronous
        // you will receive the rewards in the incentive pool at next block
        underlying.claim(validator, info.incentivePool);
        // distribute rewards if there are any
        IncentivePool(info.incentivePool).distributeReward(
            info.commissionRate,
            info.goatCommissionRate,
            info.rewardPayee
        );
    }

    // withdraw rewards for a validator without claiming from underlying staking contract
    function withdrawRewards(address validator) external {
        // anyone can call this function to claim rewards for a validator
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        IncentivePool(info.incentivePool).distributeReward(
            info.commissionRate,
            info.goatCommissionRate,
            info.rewardPayee
        );
    }

    // delegate tokens to a validator, you must be the funder
    function delegate(
        address validator,
        ILocking.Locking[] calldata values
    ) external payable {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");
        for (uint i = 0; i < values.length; i++) {
            if (values[i].token == address(0)) {
                continue; // skip native token
            }
            require(
                IERC20(values[i].token).transferFrom(
                    msg.sender,
                    address(this),
                    values[i].amount
                ),
                "Token transfer failed"
            );
            require(
                IERC20(values[i].token).approve(
                    address(underlying),
                    values[i].amount
                ),
                "Token approve failed"
            );
        }
        underlying.lock{value: msg.value}(validator, values);
    }

    // withdraw tokens from a validator, you must be the funder
    function undelegate(
        address validator,
        address recipient,
        ILocking.Locking[] calldata values
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");
        underlying.unlock(validator, recipient, values);
    }
}
