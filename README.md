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
| ValidatorEntry | 0xE6512d6202e9Ee3aE902908EC7Db46C641488Cc9 | 0x              |
| SequencerPool  | 0x47b8bD7a6b1E53B5a0006cF731490c1383B82dF1 | 0x              |

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

### Administrative helpers

Add helper functions so an admin can configure the delegate and validator owner:

```solidity
function setLockingDelegate(
    address _lockingDelegate
) public onlyRole(Constants.ADMIN_ROLE) {
    require(
        _lockingDelegate != address(0),
        "SequencerPool: INVALID_LOCKING_DELEGATE"
    );
    lockingDelegate = ILockingDelegate(_lockingDelegate);
    emit LockingDelegateSet(_lockingDelegate);
}

function changeValidatorOwner(
    address _validatorOwner
) public onlyRole(Constants.ADMIN_ROLE) {
    require(validator != address(0), "SequencerPool: NO_VALIDATOR");
    require(
        _validatorOwner != address(0),
        "SequencerPool: INVALID_VALIDATOR_OWNER"
    );
    locking.changeValidatorOwner(validator, _validatorOwner);
}
```

## Migration Steps

1. Call `setLockingDelegate(<DELEGATE_CONTRACT_ADDRESS>)` on the SequencerPool.
2. Call `changeValidatorOwner(<DELEGATE_CONTRACT_ADDRESS>)` on the SequencerPool.
3. Call `migrate(<VALIDATOR_ADDRESS>, <OPERATOR_ADDRESS>, <DISTRIBUTOR_CONTRACT_ADDRESS>, <SEQUENCER_POOL_ADDRESS>)` on the delegate contract.

> Execute steps 2 and 3 in the same transaction to avoid front-running.

## Claiming Rewards

- The distributor receives its share automatically; no manual collection is required.
- Periodically call `claim()` on the SequencerPool or `claimRewards(<VALIDATOR_ADDRESS>)` on the delegate contract.
- From the operator address, call `withdrawRewards(<VALIDATOR_ADDRESS>)` on the delegate contract.
