// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILocking} from "./interfaces/IGoatLocking.sol";
import {IncentivePool} from "./IncentivePool.sol";

contract ValidatorEntryUpgradeable is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant MAX_VALIDATOR_COUNT = 200;

    ILocking public underlying;
    IERC20 public rewardToken;

    mapping(address validator => ValidatorInfo info) public validators;

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

    event FoundationUpdated(address foundation);

    event ValidatorFunderPayeeUpdated(address validator, address funderPayee);
    event ValidatorOperatorUpdated(address validator, address operator);

    struct ValidatorInfo {
        address payable incentivePool;
        address funderPayee;
        address funder;
        address operator;
        uint256 index;
    }

    address public foundation;
    uint256 public foundationNativeCommissionRate;
    uint256 public operatorNativeCommissionRate;
    uint256 public foundationGoatCommissionRate;
    uint256 public operatorGoatCommissionRate;

    address[] private validatorList;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        ILocking _underlying,
        IERC20 _rewardToken,
        address _foundation,
        address initialOwner
    ) external initializer {
        require(
            address(_underlying) != address(0),
            "Invalid underlying address"
        );
        require(
            address(_rewardToken) != address(0),
            "Invalid rewardToken address"
        );
        require(_foundation != address(0), "Invalid foundation address");

        __Ownable_init(
            initialOwner == address(0) ? _msgSender() : initialOwner
        );

        underlying = _underlying;
        rewardToken = _rewardToken;
        foundation = _foundation;
    }

    function setFoundation(address newFoundation) external onlyOwner {
        require(newFoundation != address(0), "Invalid foundation address");
        address oldFoundation = foundation;
        require(oldFoundation != newFoundation, "Foundation unchanged");

        if (oldFoundation != address(0)) {
            for (uint256 i = 0; i < validatorList.length; i++) {
                address validator = validatorList[i];
                address payable pool = validators[validator].incentivePool;
                if (pool != address(0)) {
                    IncentivePool(pool).reassignCommission(
                        oldFoundation,
                        newFoundation
                    );
                }
            }
        }

        foundation = newFoundation;
        emit FoundationUpdated(newFoundation);
    }

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
        require(foundation != address(0), "Foundation not set");
        require(operator != address(0), "Invalid operator payee");
        require(funderPayee != address(0), "Invalid funder payee address");
        require(funder != address(0), "Invalid funder address");
        require(
            validatorList.length < MAX_VALIDATOR_COUNT,
            "Validator limit reached"
        );

        validators[validator] = ValidatorInfo({
            incentivePool: payable(address(new IncentivePool(rewardToken))),
            funderPayee: funderPayee,
            funder: funder,
            operator: operator,
            index: validatorList.length
        });

        validatorList.push(validator);

        emit ValidatorMigrated(
            validator,
            validators[validator].incentivePool,
            funderPayee,
            funder
        );
    }

    function migrateTo(address validator, address newOwner) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");

        IncentivePool(info.incentivePool).distributeReward(
            info.funderPayee,
            foundation,
            info.operator,
            foundationNativeCommissionRate,
            foundationGoatCommissionRate,
            operatorNativeCommissionRate,
            operatorGoatCommissionRate
        );

        IncentivePool(info.incentivePool).withdrawCommissions(
            foundation,
            foundation
        );
        IncentivePool(info.incentivePool).withdrawCommissions(
            info.operator,
            info.operator
        );

        underlying.changeValidatorOwner(validator, newOwner);
        _removeValidator(validator, info.index);
        delete validators[validator];
    }

    function setFunderPayee(address validator, address funderPayee) external {
        ValidatorInfo storage info = validators[validator];
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
        require(info.operator != operator, "Operator unchanged");

        IncentivePool(info.incentivePool).reassignCommission(
            info.operator,
            operator
        );
        info.operator = operator;

        emit ValidatorOperatorUpdated(validator, operator);
    }

    function withdrawCommissions(address validator, address to) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        require(to != address(0), "Invalid address");
        require(
            msg.sender == foundation || msg.sender == info.operator,
            "Not commission owner"
        );

        IncentivePool(info.incentivePool).withdrawCommissions(msg.sender, to);
    }

    function withdrawFoundationCommissions(address to) external {
        require(msg.sender == foundation, "Not foundation");
        require(to != address(0), "Invalid address");

        for (uint256 i = 0; i < validatorList.length; i++) {
            address payable pool = validators[validatorList[i]].incentivePool;
            if (pool != address(0)) {
                IncentivePool(pool).withdrawCommissions(foundation, to);
            }
        }
    }

    function claimRewards(address validator) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");

        underlying.claim(validator, info.incentivePool);
        _distributeReward(info);
    }

    function withdrawRewards(address validator) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");

        _distributeReward(info);
    }

    function delegate(
        address validator,
        ILocking.Locking[] calldata values
    ) external payable {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");

        for (uint256 i = 0; i < values.length; i++) {
            if (values[i].token == address(0)) {
                continue;
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
        require(foundation != address(0), "Foundation not set");

        IncentivePool(info.incentivePool).distributeReward(
            info.funderPayee,
            foundation,
            info.operator,
            foundationNativeCommissionRate,
            foundationGoatCommissionRate,
            operatorNativeCommissionRate,
            operatorGoatCommissionRate
        );
    }

    function _removeValidator(address validator, uint256 index) internal {
        require(validatorList[index] == validator, "Index mismatch");

        uint256 lastIndex = validatorList.length - 1;
        if (index != lastIndex) {
            address lastValidator = validatorList[lastIndex];
            validatorList[index] = lastValidator;
            validators[lastValidator].index = index;
        }

        validatorList.pop();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    uint256[49] private __gap;
}
