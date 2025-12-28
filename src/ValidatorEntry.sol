// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILocking} from "./interfaces/IGoatLocking.sol";
import {IncentivePool} from "./IncentivePool.sol";

/**
 * @title ValidatorEntry
 * @notice Coordinates the lifecycle of validators for the GOAT locking system.
 * Manages validator migration, role configuration, and reward distribution via
 * dedicated `IncentivePool` instances while enforcing commission settings.
 * @dev This non-upgradeable variant relies on immutable references to the
 * underlying locking contract and the reward token.
 */
contract ValidatorEntry is Ownable {
    uint256 public constant MAX_COMMISSION_RATE = 10000; // 100%
    uint256 public constant MAX_VALIDATOR_COUNT = 200;
    uint32 public constant MIGRATION_WINDOW = 1 days;

    // the underlying staking contract address
    ILocking public immutable underlying;
    IERC20 public immutable rewardToken;

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
    event MigrationRegistered(address validator, address owner);

    struct ValidatorInfo {
        uint32 migrateDeadline; // the deadline for the migration to complete
        address funder; // the address who funded the validator locking
        address funderPayee; // the address who receives the rewards in the incentive pool
        address operator; // the address who operates the validator and receives commissions
        address payable incentivePool; // the incentive pool address for receiving rewards
        uint32 index; // position in validator list
    }

    mapping(address validator => ValidatorInfo info) public validators;

    address public foundation;
    uint256 public foundationNativeCommissionRate;
    uint256 public operatorNativeCommissionRate;
    uint256 public foundationGoatCommissionRate;
    uint256 public operatorGoatCommissionRate;

    address[] private validatorList;

    /// @notice Initializes the entry contract with immutable dependencies.
    /// @param _underlying Goat locking contract that actually manages validators.
    /// @param _rewardToken ERC20 token paid out of incentive pools.
    /// @param _foundation Address collecting the foundation commission share.
    constructor(
        ILocking _underlying,
        IERC20 _rewardToken,
        address _foundation
    ) Ownable(msg.sender) {
        require(
            address(_underlying) != address(0),
            "Invalid underlying address"
        );
        require(
            address(_rewardToken) != address(0),
            "Invalid rewardToken address"
        );
        require(_foundation != address(0), "Invalid foundation address");
        underlying = _underlying;
        rewardToken = _rewardToken;
        foundation = _foundation;
    }

    /// @notice Updates the foundation payee and prepares existing pools for the switch.
    /// @dev Pending commissions are withdrawn to the previous foundation so it can claim later.
    /// @param newFoundation Replacement foundation address.
    function setFoundation(address newFoundation) external onlyOwner {
        require(newFoundation != address(0), "Invalid foundation address");
        address oldFoundation = foundation;
        require(oldFoundation != newFoundation, "Foundation unchanged");

        if (oldFoundation != address(0)) {
            for (uint256 i; i < validatorList.length; i++) {
                address validator = validatorList[i];
                address payable pool = validators[validator].incentivePool;
                if (pool != address(0)) {
                    IncentivePool(pool).withdrawFoundationCommission(
                        oldFoundation
                    );
                }
            }
        }
        foundation = newFoundation;
        emit FoundationUpdated(newFoundation);
    }

    /// @notice Configures global commission rates for all validators.
    /// @param newFoundationNativeRate Foundation share on native rewards (bps).
    /// @param newOperatorNativeRate Operator share on native rewards (bps).
    /// @param newFoundationGoatRate Foundation share on token rewards (bps).
    /// @param newOperatorGoatRate Operator share on token rewards (bps).
    function setCommissionRates(
        uint256 newFoundationNativeRate,
        uint256 newOperatorNativeRate,
        uint256 newFoundationGoatRate,
        uint256 newOperatorGoatRate
    ) external onlyOwner {
        require(
            newFoundationNativeRate <= MAX_COMMISSION_RATE,
            "Invalid foundation native"
        );
        require(
            newOperatorNativeRate <= MAX_COMMISSION_RATE,
            "Invalid operator native"
        );
        require(
            newFoundationGoatRate <= MAX_COMMISSION_RATE,
            "Invalid foundation goat"
        );
        require(
            newOperatorGoatRate <= MAX_COMMISSION_RATE,
            "Invalid operator goat"
        );
        require(
            newFoundationNativeRate + newOperatorNativeRate <=
                MAX_COMMISSION_RATE,
            "Native rate overflow"
        );
        require(
            newFoundationGoatRate + newOperatorGoatRate <= MAX_COMMISSION_RATE,
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

    /// @notice Registers a migration for a validator.
    /// @param validator Validator being migrated.
    function registerMigration(address validator) external {
        ValidatorInfo storage info = validators[validator];
        require(address(info.incentivePool) == address(0), "Already migrated");
        require(block.timestamp > info.migrateDeadline, "Ongoing migration");
        info.migrateDeadline = uint32(block.timestamp + MIGRATION_WINDOW);
        info.funder = msg.sender;
        emit MigrationRegistered(validator, msg.sender);
    }

    /// @notice Deploys an incentive pool and tracks metadata for a validator.
    /// @dev Must be coordinated with `underlying.changeValidatorOwner`.
    /// @param validator Validator address being migrated.
    /// @param operator Operator receiving commissions.
    /// @param funderPayee Recipient of net rewards.
    /// @param funder Address that controls delegation/undelegation.
    /// @param operatorNativeAllowance Allowance cap for native commission per period.
    /// @param operatorTokenAllowance Allowance cap for token commission per period.
    /// @param allowanceUpdatePeriod Period length for refreshing allowances.
    function migrate(
        address validator,
        address operator,
        address funderPayee,
        address funder,
        uint256 operatorNativeAllowance,
        uint256 operatorTokenAllowance,
        uint256 allowanceUpdatePeriod
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(block.timestamp <= info.migrateDeadline, "Migration expired");
        require(address(this) == underlying.owners(validator), "Not the owner");
        require(msg.sender == info.funder, "Not registered");
        require(foundation != address(0), "Foundation not set");
        require(operator != address(0), "Invalid operator payee");
        require(funderPayee != address(0), "Invalid funder payee address");
        require(funder != address(0), "Invalid funder address");
        require(
            validatorList.length < MAX_VALIDATOR_COUNT,
            "Validator limit reached"
        );
        address payable pool = payable(
            address(
                new IncentivePool(
                    rewardToken,
                    operatorNativeAllowance,
                    operatorTokenAllowance,
                    allowanceUpdatePeriod
                )
            )
        );
        validators[validator] = ValidatorInfo({
            migrateDeadline: 0,
            funder: funder,
            funderPayee: funderPayee,
            operator: operator,
            incentivePool: pool,
            index: uint32(validatorList.length)
        });
        validatorList.push(validator);
        emit ValidatorMigrated(
            validator,
            validators[validator].incentivePool,
            funderPayee,
            funder
        );
    }

    /// @notice Moves a validator away from this entry contract and cleanup the incentive pool.
    /// @param validator Validator being migrated out.
    /// @param newOwner Contract that will own the validator afterwards.
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
        IncentivePool(info.incentivePool).withdrawFoundationCommission(
            foundation
        );
        IncentivePool(info.incentivePool).withdrawOperatorCommission(
            info.operator
        );
        underlying.changeValidatorOwner(validator, newOwner);
        _removeValidator(validator, info.index);
        delete validators[validator];
    }

    /// @notice Updates the reward payee for a validator.
    /// @param validator Target validator.
    /// @param funderPayee New recipient for reward payouts.
    function setFunderPayee(address validator, address funderPayee) external {
        ValidatorInfo storage info = validators[validator];
        // allow funder to change reward payee
        require(msg.sender == info.funder, "Not the funder");
        require(funderPayee != address(0), "Invalid funder payee address");
        info.funderPayee = funderPayee;
        emit ValidatorFunderPayeeUpdated(validator, funderPayee);
    }

    /// @notice Rotates the operator for a validator.
    /// @dev Pending operator commissions are withdrawn to the old operator first.
    /// @param validator Target validator.
    /// @param operator New operator address.
    function setOperator(address validator, address operator) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        require(msg.sender == info.operator, "Not operator");
        require(operator != address(0), "Invalid operator address");
        require(info.operator != operator, "Operator unchanged");
        IncentivePool(info.incentivePool).withdrawOperatorCommission(
            info.operator
        );
        info.operator = operator;
        emit ValidatorOperatorUpdated(validator, operator);
    }

    /// @notice Updates allowance caps a validator's operator can earn per period.
    /// @param validator Target validator.
    /// @param nativeAllowance Allowed native commission per window.
    /// @param tokenAllowance Allowed token commission per window.
    /// @param updatePeriod Duration of a single window.
    function setOperatorAllowanceConfig(
        address validator,
        uint256 nativeAllowance,
        uint256 tokenAllowance,
        uint256 updatePeriod
    ) external onlyOwner {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        IncentivePool(info.incentivePool).setOperatorAllowanceConfig(
            nativeAllowance,
            tokenAllowance,
            updatePeriod
        );
    }

    /// @notice Withdraws the foundation's commissions for a validator.
    /// @param validator Target validator.
    /// @param to Destination wallet for funds.
    function withdrawFoundationCommission(
        address validator,
        address to
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        require(msg.sender == foundation, "Not foundation");
        require(to != address(0), "Invalid address");
        IncentivePool(info.incentivePool).withdrawFoundationCommission(to);
    }

    /// @notice Withdraws the operator's commissions for a validator.
    /// @param validator Target validator.
    /// @param to Destination wallet for funds.
    function withdrawOperatorCommission(
        address validator,
        address to
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        require(msg.sender == info.operator, "Not operator");
        require(to != address(0), "Invalid address");
        IncentivePool(info.incentivePool).withdrawOperatorCommission(to);
    }

    /// @notice Withdraws the foundation commissions across all validators.
    /// @param to Destination wallet for funds.
    function withdrawAllFoundationCommissions(address to) external {
        require(msg.sender == foundation, "Not foundation");
        require(to != address(0), "Invalid address");
        for (uint256 i; i < validatorList.length; i++) {
            address payable pool = validators[validatorList[i]].incentivePool;
            if (pool != address(0)) {
                IncentivePool(pool).withdrawFoundationCommission(to);
            }
        }
    }

    /// @notice Claims pending rewards from the locking contract and distributes them.
    /// @param validator Target validator.
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

    /// @notice Distributes whatever rewards are already in the incentive pool.
    /// @param validator Target validator.
    function withdrawRewards(address validator) external {
        // anyone can call this function to claim rewards for a validator
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        _distributeReward(info);
    }

    /// @notice Locks additional funds into the underlying validator.
    /// @param validator Target validator.
    /// @param values Locking instructions forwarded to the underlying contract.
    function delegate(
        address validator,
        ILocking.Locking[] calldata values
    ) external payable {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");
        for (uint256 i; i < values.length; i++) {
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

    /// @notice Unlocks funds from the underlying validator.
    /// @param validator Target validator.
    /// @param recipient Address receiving unlocked funds.
    /// @param values Unlocking instructions forwarded to the underlying contract.
    function undelegate(
        address validator,
        address recipient,
        ILocking.Locking[] calldata values
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");
        underlying.unlock(validator, recipient, values);
    }

    /// @dev Pushes rewards plus commissions to the appropriate parties.
    /// @param info Validator metadata containing the incentive pool reference.
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

    /// @dev Removes a validator from the in-memory list in O(1) time.
    /// @param validator Validator address to remove.
    /// @param index Expected index in the array.
    function _removeValidator(address validator, uint256 index) internal {
        require(validatorList[index] == validator, "Index mismatch");
        uint256 lastIndex = validatorList.length - 1;
        if (index != lastIndex) {
            address lastValidator = validatorList[lastIndex];
            validatorList[index] = lastValidator;
            validators[lastValidator].index = uint32(index);
        }
        validatorList.pop();
    }
}
