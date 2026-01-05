// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILocking} from "./interfaces/IGoatLocking.sol";
import {IncentivePool} from "./IncentivePool.sol";

/**
 * @title ValidatorEntryUpgradeable
 * @notice Upgradeable entrypoint for managing GOAT validators, wrapping the
 * underlying locking contract with funder/operator/foundation coordination and
 * per-validator `IncentivePool` deployments.
 * @dev Mirrors `ValidatorEntry` but follows OZ's UUPS pattern so commission
 * logic and bookkeeping can evolve over time.
 */
contract ValidatorEntryUpgradeable is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant MAX_COMMISSION_RATE = 10000; // 100%
    uint256 public constant MAX_VALIDATOR_COUNT = 200;
    /// @notice The cooldown period after a validator is migrated before it can be migrated again.
    uint32 public constant MIGRATION_COOLDOWN = 7 days;

    ILocking public underlying;
    IERC20 public rewardToken;

    mapping(address validator => ValidatorInfo info) public validators;

    event ValidatorMigrated(
        address validator,
        address funder,
        address funderPayee,
        address operator,
        address incentivePool
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
        bool active;
        uint32 index;
        uint32 migrationCooldown;
        address funder;
        address funderPayee;
        address operator;
        address payable incentivePool;
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

    /// @notice Initializes the upgradeable storage.
    /// @param underlyingContract Goat locking contract that owns validators.
    /// @param rewardTokenContract ERC20 token paid from incentive pools.
    /// @param foundationAddr Foundation commission recipient.
    /// @param initialOwner Owner of the proxy (defaults to caller if zero).
    function initialize(
        ILocking underlyingContract,
        IERC20 rewardTokenContract,
        address foundationAddr,
        address initialOwner
    ) external initializer {
        require(
            address(underlyingContract) != address(0),
            "Invalid underlying address"
        );
        require(
            address(rewardTokenContract) != address(0),
            "Invalid rewardToken address"
        );
        require(foundationAddr != address(0), "Invalid foundation address");

        __Ownable_init(
            initialOwner == address(0) ? _msgSender() : initialOwner
        );

        underlying = underlyingContract;
        rewardToken = rewardTokenContract;
        foundation = foundationAddr;
    }

    /// @notice Updates the foundation payee.
    /// @param newFoundation Replacement foundation address.
    /// @param to Destination wallet.
    function setFoundation(
        address newFoundation,
        address to
    ) external onlyOwner {
        require(newFoundation != address(0), "Invalid foundation address");
        require(foundation != newFoundation, "Foundation unchanged");

        if (to != address(0)) {
            for (uint256 i; i < validatorList.length; i++) {
                address payable pool = validators[validatorList[i]]
                    .incentivePool;
                if (pool != address(0)) {
                    IncentivePool(pool).withdrawFoundationCommission(to);
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

    /// @notice Registers a migration intent for a validator.
    /// @param validator Validator being migrated.
    function registerMigration(address validator) external {
        ValidatorInfo storage info = validators[validator];
        require(!info.active, "Already migrated");
        require(msg.sender == underlying.owners(validator), "Not the owner");
        info.funder = msg.sender;
        emit MigrationRegistered(validator, msg.sender);
    }

    /// @notice Deploys a dedicated incentive pool for the validator.
    /// @param validator Validator address being migrated.
    /// @param operator Operator receiving commissions.
    /// @param funderPayee Recipient of net rewards.
    /// @param funder Address that owns deposits.
    /// @param operatorNativeAllowance Allowance cap for native commissions.
    /// @param operatorTokenAllowance Allowance cap for token commissions.
    /// @param allowanceUpdatePeriod Duration of allowance windows.
    function migrate(
        address validator,
        address funder,
        address funderPayee,
        address operator,
        uint256 operatorNativeAllowance,
        uint256 operatorTokenAllowance,
        uint256 allowanceUpdatePeriod
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(!info.active, "Already migrated");
        require(address(this) == underlying.owners(validator), "Not the owner");
        require(msg.sender == info.funder, "Not registered");
        require(
            block.timestamp >= info.migrationCooldown,
            "Migration window not expired"
        );
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
            active: true,
            index: uint32(validatorList.length),
            migrationCooldown: 0,
            funder: funder,
            funderPayee: funderPayee,
            operator: operator,
            incentivePool: pool
        });

        validatorList.push(validator);

        emit ValidatorMigrated(
            validator,
            funder,
            funderPayee,
            operator,
            validators[validator].incentivePool
        );
    }

    /// @notice Removes a validator and hands ownership to a new contract and cleanup the incentive pool.
    /// @param validator Validator being migrated away.
    /// @param newOwner Target contract that should become validator owner.
    function migrateTo(address validator, address newOwner) external {
        ValidatorInfo storage info = validators[validator];
        require(info.active, "Not migrated");
        require(msg.sender == info.funder, "Not the funder");

        _distributeReward(info);
        underlying.claim(validator, info.incentivePool);
        underlying.changeValidatorOwner(validator, newOwner);
        _removeValidator(validator, info.index);
        info.active = false;
        info.migrationCooldown = uint32(block.timestamp + MIGRATION_COOLDOWN);
    }

    /// @notice Updates the funder payee address.
    /// @param validator Target validator.
    /// @param funderPayee New reward recipient.
    function setFunderPayee(address validator, address funderPayee) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");
        require(funderPayee != address(0), "Invalid funder payee address");

        info.funderPayee = funderPayee;

        emit ValidatorFunderPayeeUpdated(validator, funderPayee);
    }

    /// @notice Rotates the validator operator.
    /// @param validator Target validator.
    /// @param operator New operator payee.
    /// @param to Destination wallet.
    function setOperator(
        address validator,
        address operator,
        address to
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");
        require(msg.sender == info.operator, "Not operator");
        require(operator != address(0), "Invalid operator address");
        require(info.operator != operator, "Operator unchanged");
        if (to != address(0)) {
            IncentivePool(info.incentivePool).withdrawOperatorCommission(to);
        }
        info.operator = operator;

        emit ValidatorOperatorUpdated(validator, operator);
    }

    /// @notice Sets allowance caps for operator commissions.
    /// @param validator Target validator.
    /// @param nativeAllowance Allowed native commission per period.
    /// @param tokenAllowance Allowed token commission per period.
    /// @param updatePeriod Duration of the enforcement window.
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
    /// @param to Destination wallet.
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
    /// @param to Destination wallet.
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
    /// @param to Destination wallet.
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

    /// @notice Claims rewards from the underlying locking contract.
    /// @param validator Target validator.
    function claimRewards(address validator) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");

        underlying.claim(validator, info.incentivePool);
        _distributeReward(info);
    }

    /// @notice Distributes rewards already stored in the incentive pool.
    /// @param validator Target validator.
    function withdrawRewards(address validator) external {
        ValidatorInfo storage info = validators[validator];
        require(info.incentivePool != address(0), "Not migrated");

        _distributeReward(info);
    }

    /// @notice Delegates assets to the underlying validator.
    /// @param validator Target validator.
    /// @param values Lock instructions forwarded to the locking contract.
    function delegate(
        address validator,
        ILocking.Locking[] calldata values
    ) external payable {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");

        for (uint256 i; i < values.length; i++) {
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

    /// @notice Unlocks assets from the underlying validator.
    /// @param validator Target validator.
    /// @param recipient Address receiving unlocked funds.
    /// @param values Unlock instructions forwarded to the locking contract.
    function undelegate(
        address validator,
        address recipient,
        ILocking.Locking[] calldata values
    ) external {
        ValidatorInfo storage info = validators[validator];
        require(msg.sender == info.funder, "Not the funder");

        underlying.unlock(validator, recipient, values);
    }

    /// @dev Pushes rewards plus commissions to the relevant parties.
    /// @param info Validator metadata referencing the incentive pool.
    function _distributeReward(ValidatorInfo storage info) internal {
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

    /// @dev Removes a validator from storage in O(1) time.
    /// @param validator Address to remove.
    /// @param index Expected index in `validatorList`.
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

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    uint256[50] private __gap;
}
