// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILocking} from "./interfaces/IGoatLocking.sol";
import {IncentivePool} from "./IncentivePool.sol";

contract ValidatorEntry is Ownable {
    // the underlying staking contract address
    ILocking public immutable underlying;
    IERC20 public immutable rewardToken;

    mapping(address validator => ValidatorInfo info) validators;

    event ValidatorMigrated(
        address validator,
        address incentivePool,
        address funderPayee,
        address funder
    );

    event CommissionRatesUpdated(
        uint256 foundationNativeRate,
        uint256 operatorNativeRate,
        uint256 foundationGoatRate,
        uint256 operatorGoatRate
    );

    event FoundationPayeeUpdated(address foundationPayee);

    event ValidatorFunderPayeeUpdated(address validator, address funderPayee);
    event ValidatorOperatorUpdated(address validator, address operator);

    struct ValidatorInfo {
        address incentivePool; // the incentive pool address for receiving rewards
        address funderPayee; // the address who receives the rewards in the incentive pool
        address funder; // the address who funded the validator locking
        address operator; // the address who operates the validator and receives commissions
    }

    address public foundationPayee;
    uint256 public foundationNativeCommissionRate;
    uint256 public operatorNativeCommissionRate;
    uint256 public foundationGoatCommissionRate;
    uint256 public operatorGoatCommissionRate;

    constructor(ILocking _underlying, IERC20 _rewardToken) Ownable(msg.sender) {
        underlying = _underlying;
        rewardToken = _rewardToken;
    }

    function setFoundationPayee(address newFoundationPayee) external onlyOwner {
        require(newFoundationPayee != address(0), "Invalid foundation address");
        foundationPayee = newFoundationPayee;
        emit FoundationPayeeUpdated(newFoundationPayee);
    }

    // set commission configuration for validators, you must be the owner
    function setCommissionRates(
        uint256 newFoundationNativeRate,
        uint256 newOperatorNativeRate,
        uint256 newFoundationGoatRate,
        uint256 newOperatorGoatRate
    ) external onlyOwner {
        require(newFoundationNativeRate <= 1e4, "Invalid foundation native");
        require(newOperatorNativeRate <= 1e4, "Invalid operator native");
        require(newFoundationGoatRate <= 1e4, "Invalid foundation goat");
        require(newOperatorGoatRate <= 1e4, "Invalid operator goat");
        require(
            newFoundationNativeRate + newOperatorNativeRate <= 1e4,
            "Native rate overflow"
        );
        require(
            newFoundationGoatRate + newOperatorGoatRate <= 1e4,
            "Goat rate overflow"
        );

        foundationNativeCommissionRate = newFoundationNativeRate;
        operatorNativeCommissionRate = newOperatorNativeRate;
        foundationGoatCommissionRate = newFoundationGoatRate;
        operatorGoatCommissionRate = newOperatorGoatRate;

        emit CommissionRatesUpdated(
            newFoundationNativeRate,
            newOperatorNativeRate,
            newFoundationGoatRate,
            newOperatorGoatRate
        );
    }

    // migrate a validator to this contract
    // You must call this function with the changeValidatorOwner call in the same transaction
    function migrate(
        address validator,
        address operator,
        address funderPayee,
        address funder
    ) external {
        require(address(this) == underlying.owners(validator), "Not the owner");
        require(
            address(validators[validator].incentivePool) == address(0),
            "Already migrated"
        );
        require(foundationPayee != address(0), "Foundation not set");
        require(operator != address(0), "Invalid operator payee");
        require(funderPayee != address(0), "Invalid funder payee address");
        require(funder != address(0), "Invalid funder address");
        validators[validator] = ValidatorInfo({
            incentivePool: address(new IncentivePool(rewardToken)),
            funderPayee: funderPayee,
            funder: funder,
            operator: operator
        });
        emit ValidatorMigrated(
            validator,
            validators[validator].incentivePool,
            funderPayee,
            funder
        );
    }

    // migrate from this contract to another one and cleanup the incentive pool
    function migrateTo(address validator, address newOwner) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");
        IncentivePool(info.incentivePool).distributeReward(
            info.funderPayee,
            foundationPayee,
            info.operator,
            foundationNativeCommissionRate,
            foundationGoatCommissionRate,
            operatorNativeCommissionRate,
            operatorGoatCommissionRate
        );
        IncentivePool(info.incentivePool).withdrawCommissions(
            foundationPayee,
            foundationPayee
        );
        IncentivePool(info.incentivePool).withdrawCommissions(
            info.operator,
            info.operator
        );
        underlying.changeValidatorOwner(validator, newOwner);
        delete validators[validator];
    }

    // set reward payee for a validator, you must be the funder
    function setFunderPayee(address validator, address funderPayee) external {
        ValidatorInfo storage info = validators[validator];
        // allow funder to change reward payee
        require(msg.sender == info.funder, "Not the funder");
        require(funderPayee != address(0), "Invalid funder payee address");
        info.funderPayee = funderPayee;
        emit ValidatorFunderPayeeUpdated(validator, funderPayee);
    }

    function setOperator(address validator, address operator) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        require(msg.sender == info.operator, "Not operator");
        require(operator != address(0), "Invalid operator address");
        info.operator = operator;
        emit ValidatorOperatorUpdated(validator, operator);
    }

    // withdraw commissions for a validator
    function withdrawCommissions(address validator, address to) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        require(to != address(0), "Invalid address");
        require(
            msg.sender == foundationPayee || msg.sender == info.operator,
            "Not commission owner"
        );
        IncentivePool(info.incentivePool).withdrawCommissions(msg.sender, to);
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
        _distributeReward(info);
    }

    // withdraw rewards for a validator without claiming from underlying staking contract
    function withdrawRewards(address validator) external {
        // anyone can call this function to claim rewards for a validator
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        _distributeReward(info);
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

    function _distributeReward(ValidatorInfo storage info) internal {
        require(foundationPayee != address(0), "Foundation not set");
        IncentivePool(info.incentivePool).distributeReward(
            info.funderPayee,
            foundationPayee,
            info.operator,
            foundationNativeCommissionRate,
            foundationGoatCommissionRate,
            operatorNativeCommissionRate,
            operatorGoatCommissionRate
        );
    }
}
