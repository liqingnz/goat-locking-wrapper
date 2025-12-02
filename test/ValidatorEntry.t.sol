// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {ValidatorEntry} from "src/ValidatorEntry.sol";
import {IncentivePool} from "src/IncentivePool.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockLocking} from "test/mocks/MockLocking.sol";

contract ValidatorEntryTest is Test {
    MockLocking private locking;
    MockERC20 private token;
    ValidatorEntry private entry;

    address private constant FOUNDATION = address(0xF2);
    address private constant OPERATOR = address(0xF3);
    address private constant FUNDER = address(0xF4);
    address private constant FUNDER_PAYEE = address(0xF5);
    address private constant VALIDATOR = address(0xBEEF);

    function setUp() public {
        locking = new MockLocking();
        token = new MockERC20();
        entry = new ValidatorEntry(locking, token, FOUNDATION);

        entry.setCommissionRates(2_000, 3_000, 5_000, 4_000);
        locking.setOwner(VALIDATOR, address(entry));
    }

    function testDistributeRewardViaValidatorEntry() public {
        address payable poolAddr = _migrateDefault(10 ether, 1_000 ether);
        _fundPool(poolAddr, 10 ether, 1_000 ether);

        entry.withdrawRewards(VALIDATOR);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(pool.foundationNativeCommission(), 2 ether);
        assertEq(pool.operatorNativeCommission(), 3 ether);
        assertEq(pool.foundationTokenCommission(), 500 ether);
        assertEq(pool.operatorTokenCommission(), 400 ether);
    }

    function testWithdrawsRespectRoles() public {
        address payable poolAddr = _migrateDefault(10 ether, 1_000 ether);
        _fundPool(poolAddr, 5 ether, 200 ether);
        entry.withdrawRewards(VALIDATOR);

        uint256 foundationNativeBefore = FOUNDATION.balance;
        uint256 operatorNativeBefore = OPERATOR.balance;

        vm.prank(FOUNDATION);
        entry.withdrawFoundationCommission(VALIDATOR, FOUNDATION);
        vm.prank(OPERATOR);
        entry.withdrawOperatorCommission(VALIDATOR, OPERATOR);

        assertEq(FOUNDATION.balance - foundationNativeBefore, 1 ether);
        assertEq(OPERATOR.balance - operatorNativeBefore, 1.5 ether);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(pool.foundationTokenCommission(), 0);
        assertEq(pool.operatorTokenCommission(), 0);
    }

    function testOperatorAllowanceCapsShare() public {
        address payable poolAddr = _migrateDefault(1 ether, 100 ether);
        _fundPool(poolAddr, 10 ether, 1_000 ether);

        entry.withdrawRewards(VALIDATOR);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(pool.operatorNativeCommission(), 1 ether);
        assertEq(pool.operatorTokenCommission(), 100 ether);
    }

    function _migrateDefault(
        uint256 nativeAllowance,
        uint256 tokenAllowance
    ) internal returns (address payable poolAddr) {
        entry.migrate(
            VALIDATOR,
            OPERATOR,
            FUNDER_PAYEE,
            FUNDER,
            nativeAllowance,
            tokenAllowance,
            0
        );
        (poolAddr, , , , ) = entry.validators(VALIDATOR);
    }

    function _fundPool(
        address payable poolAddr,
        uint256 nativeAmount,
        uint256 tokenAmount
    ) internal {
        vm.deal(address(this), nativeAmount);
        (bool sent, ) = poolAddr.call{value: nativeAmount}("");
        require(sent, "fund native");
        if (tokenAmount > 0) {
            token.mint(poolAddr, tokenAmount);
        }
    }
}
