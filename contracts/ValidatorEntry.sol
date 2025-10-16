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
        uint256 commissionRate
    );

    event ValidatorCommissionRateUpdated(
        address validator,
        uint256 commissionRate
    );

    event ValidatorRewardPayeeUpdated(address validator, address rewardPayee);

    struct ValidatorInfo {
        address owner; // the owner of the validator in this contract
        IncentivePool incentivePool; // the incentive pool address for receiving rewards
        address rewardPayee; // the address who receives the rewards in the incentive pool
        address funder; // the address who funded the validator locking
        uint256 commissionRate; // the commission rate in basis points (1e4 = 100%)
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
        uint256 commissionRate
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
            incentivePool: new IncentivePool(rewardToken),
            rewardPayee: rewardPayee,
            funder: funder,
            commissionRate: commissionRate
        });
        emit ValidatorMigrated(
            validator,
            owner,
            address(validators[validator].incentivePool),
            rewardPayee,
            funder,
            commissionRate
        );
    }

    // migrate a validator to another owner and clearup the incentive pool
    function migrateTo(address validator, address newOwner) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.owner, "Not the owner");
        info.incentivePool.distributeReward(
            info.commissionRate,
            info.rewardPayee
        );
        info.incentivePool.withdrawCommissions(info.owner);
        underlying.changeValidatorOwner(validator, newOwner);
        delete validators[validator];
    }

    function setCommissionRate(
        address validator,
        uint256 commissionRate
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.owner, "Not the owner");
        require(commissionRate <= 1e4, "Invalid commission rate");
        info.commissionRate = commissionRate;
        emit ValidatorCommissionRateUpdated(validator, commissionRate);
    }

    function setRewardPayee(address validator, address rewardPayee) external {
        ValidatorInfo storage info = validators[validator];
        // allow funder to change reward payee
        require(msg.sender == info.funder, "Not the funder");
        require(rewardPayee != address(0), "Invalid reward payee address");
        info.rewardPayee = rewardPayee;
        emit ValidatorRewardPayeeUpdated(validator, rewardPayee);
    }

    function withdrawCommissions(address validator, address to) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.owner, "Not the owner");
        info.incentivePool.withdrawCommissions(to); // it checks if the address is valid
    }

    function claimRewards(address validator) external {
        // anyone can call this function to claim rewards for a validator
        ValidatorInfo storage info = validators[validator];
        underlying.claim(validator, address(info.incentivePool));
        // distribute rewards if there are any
        // TODO: we need to disscuss whether we should have a separate function to distribute rewards
        info.incentivePool.distributeReward(
            info.commissionRate,
            info.rewardPayee
        );
    }

    function delegate(
        address validator,
        ILocking.Locking[] calldata values
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");
        underlying.lock(validator, values);
    }

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
