// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILocking} from "src/interfaces/IGoatLocking.sol";

contract MockLocking is ILocking {
    mapping(address => address) private _owners;

    function setOwner(address validator, address owner) external {
        _owners[validator] = owner;
    }

    function owners(address validator) external view override returns (address) {
        return _owners[validator];
    }

    function changeValidatorOwner(address validator, address newOwner) external override {
        _owners[validator] = newOwner;
    }

    function claim(address, address) external override {}

    function lock(address, Locking[] calldata) external payable override {}

    function unlock(address, address, Locking[] calldata) external override {}

    function create(
        bytes32[2] calldata,
        bytes32,
        bytes32,
        uint8
    ) external payable override {}

    function creationThreshold() external pure override returns (Locking[] memory thresholds) {
        thresholds = new Locking[](0);
    }

    function getAddressByPubkey(bytes32[2] calldata)
        external
        pure
        override
        returns (address, address)
    {
        return (address(0), address(0));
    }

    function reclaim() external override {}
}
