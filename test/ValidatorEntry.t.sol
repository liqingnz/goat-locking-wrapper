// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ValidatorEntryUpgradeable} from "src/ValidatorEntryUpgradeable.sol";
import {IncentivePool} from "src/IncentivePool.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockLocking} from "test/mocks/MockLocking.sol";

contract ValidatorEntryUpgradeableV2 is ValidatorEntryUpgradeable {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract ValidatorEntryUpgradeableTest is Test {
    MockLocking private locking;
    MockERC20 private token;
    ValidatorEntryUpgradeable private entry;

    address private constant FOUNDATION = address(0xF2);
    address private constant OPERATOR = address(0xF3);
    address private constant FUNDER = address(0xF4);
    address private constant FUNDER_PAYEE = address(0xF5);
    address private constant VALIDATOR = address(0xBEEF);

    function setUp() public {
        locking = new MockLocking();
        token = new MockERC20();
        ValidatorEntryUpgradeable implementation = new ValidatorEntryUpgradeable();
        bytes memory initData = abi.encodeWithSelector(
            ValidatorEntryUpgradeable.initialize.selector,
            locking,
            token,
            FOUNDATION,
            address(this)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        entry = ValidatorEntryUpgradeable(payable(address(proxy)));

        entry.setCommissionRates(2_000, 3_000, 5_000, 4_000);
        locking.setOwner(VALIDATOR, FUNDER);
    }

    function testUpgradeToNewImplementation() public {
        ValidatorEntryUpgradeableV2 newImpl = new ValidatorEntryUpgradeableV2();
        address nonOwner = address(0xB0B);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                nonOwner
            )
        );
        vm.prank(nonOwner);
        entry.upgradeToAndCall(address(newImpl), "");
        vm.prank(address(this));
        entry.upgradeToAndCall(address(newImpl), "");
        assertEq(ValidatorEntryUpgradeableV2(address(entry)).version(), "v2");
    }

    function testDistributeRewardViaValidatorEntry() public {
        address payable poolAddr = _migrateDefault(10 ether, 1_000 ether);
        _fundPool(poolAddr, 10 ether, 1_000 ether);

        uint256 funderNativeBefore = FUNDER_PAYEE.balance;
        uint256 funderTokenBefore = token.balanceOf(FUNDER_PAYEE);

        entry.withdrawRewards(VALIDATOR);

        IncentivePool pool = IncentivePool(poolAddr);
        assertEq(pool.foundationNativeCommission(), 2 ether);
        assertEq(pool.operatorNativeCommission(), 3 ether);
        assertEq(pool.foundationTokenCommission(), 500 ether);
        assertEq(pool.operatorTokenCommission(), 400 ether);
        assertEq(FUNDER_PAYEE.balance - funderNativeBefore, 5 ether);
        assertEq(token.balanceOf(FUNDER_PAYEE) - funderTokenBefore, 100 ether);
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
        vm.prank(FUNDER);
        entry.registerMigration(VALIDATOR);
        vm.prank(FUNDER);
        locking.changeValidatorOwner(VALIDATOR, address(entry));
        vm.prank(FUNDER);
        entry.migrate(
            VALIDATOR,
            FUNDER,
            FUNDER_PAYEE,
            OPERATOR,
            nativeAllowance,
            tokenAllowance,
            0
        );
        bool isActive;
        uint32 index_;
        (isActive, , , , poolAddr, index_) = entry.validators(VALIDATOR);
        assertTrue(isActive);
    }

    function testRegisterMigrationRevertsWhileActive() public {
        _migrateDefault(10 ether, 1_000 ether);
        vm.prank(address(entry));
        locking.changeValidatorOwner(VALIDATOR, FUNDER);
        vm.expectRevert("Already migrated");
        vm.prank(FUNDER);
        entry.registerMigration(VALIDATOR);
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
