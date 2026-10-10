// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 20: Ownable2Step handoff and privilege-boundary regressions.
/// @dev Local Foundry/CI only; no live-chain writes.
contract MEOwnershipHandoffGate20Test is Test {
    ME internal me;
    address internal nextOwner = address(0xB0B);
    address internal outsider = address(0xBAD);
    address internal recipient = address(0xCAFE);

    function setUp() public {
        me = new ME();
        vm.deal(address(this), 2 ether);
        vm.deal(nextOwner, 2 ether);
    }

    function test_TransferOnlyNominatesAndDoesNotImmediatelyChangeOwner() public {
        me.transferOwnership(nextOwner);

        assertEq(me.owner(), address(this));
        assertEq(me.pendingOwner(), nextOwner);

        vm.prank(nextOwner);
        vm.expectRevert();
        me.rescueSurplusMON(recipient);

        vm.prank(outsider);
        vm.expectRevert();
        me.acceptOwnership();

        assertEq(me.owner(), address(this));
        assertEq(me.pendingOwner(), nextOwner);
    }

    function test_OnlyPendingOwnerCanAcceptAndThenPrivilegesMove() public {
        me.transferOwnership(nextOwner);

        vm.prank(outsider);
        vm.expectRevert();
        me.acceptOwnership();

        vm.prank(nextOwner);
        me.acceptOwnership();

        assertEq(me.owner(), nextOwner);
        assertEq(me.pendingOwner(), address(0));

        vm.expectRevert();
        me.transferOwnership(outsider);

        vm.prank(nextOwner);
        me.transferOwnership(outsider);
        assertEq(me.owner(), nextOwner);
        assertEq(me.pendingOwner(), outsider);
    }

    function test_CurrentOwnerCanReplacePendingOwnerBeforeAcceptance() public {
        address alternate = address(0xA17E);
        me.transferOwnership(nextOwner);
        me.transferOwnership(alternate);

        assertEq(me.owner(), address(this));
        assertEq(me.pendingOwner(), alternate);

        vm.prank(nextOwner);
        vm.expectRevert();
        me.acceptOwnership();

        vm.prank(alternate);
        me.acceptOwnership();
        assertEq(me.owner(), alternate);
    }

    function test_OldOwnerLosesRescueAuthorityAfterHandoff() public {
        vm.deal(address(me), 1 ether);
        me.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        me.acceptOwnership();

        vm.expectRevert();
        me.rescueSurplusMON(recipient);

        vm.prank(nextOwner);
        me.rescueSurplusMON(recipient);
        assertEq(address(me).balance, 0);
        assertEq(recipient.balance, 1 ether);
    }

    function test_RenounceRemainsDisabledAfterOwnershipHandoff() public {
        me.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        me.acceptOwnership();

        vm.prank(nextOwner);
        vm.expectRevert(ME.RenounceDisabled.selector);
        me.renounceOwnership();

        assertEq(me.owner(), nextOwner);
    }
}
