# GOAT Locking Wrapper Contract

GOAT validator staking management system that automatically distributes rewards to multiple participants (Funders, Operators, Foundation) through smart contracts with flexible commission configuration.

## Overview

GOAT Locking Wrapper Contract is a validator staking management system that serves as a middleware contract for the GOAT network, providing the following core values:

- **Multi-party Collaboration**: Supports three roles - Funder, Operator, and Foundation
- **Automatic Distribution**: Staking rewards are automatically distributed to all parties based on configured commission rates
- **Dual-token Rewards**: Supports both native tokens and ERC20 tokens (GOAT) as reward tokens

### Use Cases

- Staking service providers managing multiple validators
- Separated funding and operation model for validator management
- Staking pools requiring protocol-level commission collection
- Multi-token reward distribution scenarios

## Architecture

### Contract Architecture

```
┌─────────────────────────────────────────────────┐
│         ValidatorEntry (Main Contract)          │
│  - Validator lifecycle management               │
│  - Global commission rate configuration         │
│  - Role management                              │
│  - Asset delegation/undelegation                │
└──────────────┬────────────────┬─────────────────┘
               │                │
               │ Creates        │ Interacts
               │ and manages    │
               ▼                ▼
    ┌──────────────────┐    ┌──────────────────┐
    │  IncentivePool   │    │   IGoatLocking   │
    │  (per validator) │    │  (External)      │
    │  - Reward dist   │    │  - Create val    │
    │  - Commission    │    │  - Lock/unlock   │
    │  - Withdrawal    │    │  - Claim rewards │
    └──────────────────┘    └──────────────────┘
```

### Role Relationships

```
           ┌──────────┐         ┌──────────┐
           │  Owner   │         │Foundation│
           │  Admin   │         │ Protocol │
           └──────────┘         └──────────┘
                │                     │
                │ Config rates        │
                │                     │
                └─────────────────────┘
                            │
                   ┌────────▼────────┐
                   │ ValidatorEntry  │
                   └────────┬────────┘
                            │
         ┌──────────────────┼──────────────────┐
         │                  │                  │
    ┌────▼────┐        ┌────▼────┐        ┌────▼────┐
    │Validator│        │Validator│        │Validator│
    │  Pool 1 │        │  Pool 2 │        │  Pool N │
    └────┬────┘        └────┬────┘        └────┬────┘
         │                  │                  │
    ┌────┼────┐        ┌────┼────┐        ┌────┼────┐
    ▼         ▼        ▼         ▼        ▼         ▼
┌────────┐ ┌──────┐ ┌────────┐ ┌──────┐ ┌────────┐ ┌──────┐
│Operator│ │Funder│ │Operator│ │Funder│ │Operator│ │Funder│
│Node Ops│ │Invest│ │Node Ops│ │Invest│ │Node Ops│ │Invest│
└────────┘ └──────┘ └────────┘ └──────┘ └────────┘ └──────┘
```

# Sequencer Pool Integration Guide

## Deployed Contracts

| Contract       | Testnet Address                            | Mainnet Address |
| -------------- | ------------------------------------------ | --------------- |
| ValidatorEntry | 0xea95AF1A36DEe235aC290fa0Bec493271558D101 | 0x              |

## SequencerPool Contract Changes

### State variable

Add the delegate reference:

```solidity
ILockingDelegate public lockingDelegate;
```

### External calls

Replace the existing `locking` calls with the delegate equivalents:

1. `locking.lock{value: _eth}(validator, _locking);` → `lockingDelegate.delegate{value: _eth}(validator, _locking);`
2. `locking.unlock(validator, _recipient, _locking);` → `lockingDelegate.undelegate(validator, _recipient, _locking);`
3. `locking.claim(validator, distributor);` → `lockingDelegate.claimRewards(validator);`

### Example helper functions

Here is a minimal example showing how a pool contract might wire the delegate and perform the migration sequence:

```solidity
function setLockingDelegate(
    address lockingDelegateAddr
) public {
    lockingDelegate = ILockingDelegate(lockingDelegateAddr);
}

function migrateValidator(
    uint256 operatorNativeAllowance,
    uint256 operatorTokenAllowance,
    uint256 allowanceUpdatePeriod
) public {
    lockingDelegate.registerMigration(validator);
    locking.changeValidatorOwner(validator, address(lockingDelegate));
    lockingDelegate.migrate(
        validator,
        operator,
        distributor,
        address(this),
        operatorNativeAllowance,
        operatorTokenAllowance,
        allowanceUpdatePeriod
    );
}
```

## Migration Steps

1. Call `setLockingDelegate(<DELEGATE_CONTRACT_ADDRESS>)` on the SequencerPool.
2. While the SequencerPool still owns the validator, call `registerMigration(<VALIDATOR_ADDRESS>)` on the delegate contract. This pins the SequencerPool as the `funder` that is allowed to finalize the migration.
3. Call `changeValidatorOwner(<DELEGATE_CONTRACT_ADDRESS>)` on the SequencerPool so the delegate temporarily owns the validator.
4. From the SequencerPool (the recorded funder), call `migrate(<VALIDATOR_ADDRESS>, <SEQUENCER_POOL_ADDRESS>, <DISTRIBUTOR_CONTRACT_ADDRESS>, <OPERATOR_ADDRESS>, <OPERATOR_NATIVE_ALLOWANCE>, <OPERATOR_GOAT_ALLOWANCE>, <ALLOWANCE_UPDATE_PERIOD>)` on the delegate contract.

## Claiming Rewards

- The distributor receives its share automatically; no manual collection is required.
- Periodically call `claim()` on the SequencerPool or `claimRewards(<VALIDATOR_ADDRESS>)` on the delegate contract.
- From the operator address, call `withdrawRewards(<VALIDATOR_ADDRESS>)` on the delegate contract.
