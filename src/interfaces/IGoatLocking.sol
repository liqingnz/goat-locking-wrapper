// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILocking {
    struct Locking {
        address token;
        uint256 amount;
    }

    function create(
        bytes32[2] calldata pubkey,
        bytes32 sigR,
        bytes32 sigS,
        uint8 sigV
    ) external payable;

    function lock(
        address validator,
        Locking[] calldata values
    ) external payable;

    function unlock(
        address validator,
        address recipient,
        Locking[] calldata values
    ) external;

    function claim(address validator, address recipient) external;

    function creationThreshold() external view returns (Locking[] memory);

    function getAddressByPubkey(
        bytes32[2] calldata pubkey
    ) external pure returns (address, address);

    function reclaim() external;

    function owners(address validator) external view returns (address);

    function changeValidatorOwner(address validator, address newOwner) external;
}
