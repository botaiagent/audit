// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ME} from "../src/ME.sol";

contract Gate16ForeignToken is ERC20 {
    constructor() ERC20("Foreign", "FOR") {
        _mint(address(this), 1_000 ether);
    }

    function seed(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Gate 16: owner privilege boundaries and rescue safety.
/// @dev Foundry-only local tests; CI preflight is read-only.
contract MEPrivilegeBoundaryGate16Test is Test {
    ME internal me;
    Gate16ForeignToken internal foreign;
    address internal attacker = address(0xBAD);
    address internal recipient = address(0xCAFE);

    function setUp() public {
        me = new ME();
        foreign = new Gate16ForeignToken();
        foreign.seed(address(me), 7 ether);
        vm.deal(attacker, 1 ether);
    }

    function test_NonOwnerCannotClaimFeesOrRescueAssets() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        me.claimOwnerFees(payable(recipient));
        vm.expectRevert();
        me.rescueSurplusMON(recipient);
        vm.expectRevert();
        me.rescueERC20(address(foreign), recipient);
        vm.expectRevert();
        me.rescueERC721(address(foreign), 1, recipient);
        vm.expectRevert();
        me.rescueERC1155(address(foreign), 1, recipient);
        vm.stopPrank();

        assertEq(foreign.balanceOf(address(me)), 7 ether);
        assertEq(foreign.balanceOf(recipient), 0);
    }

    function test_OwnerCannotRescueMEOrWithdrawCurveReserve() public {
        uint256 meBefore = me.balanceOf(address(me));
        uint256 reserveBefore = me.reserveMON();

        vm.expectRevert(ME.CannotRescueME.selector);
        me.rescueERC20(address(me), recipient);
        vm.expectRevert(ME.CannotRescueME.selector);
        me.rescueERC721(address(me), 1, recipient);
        vm.expectRevert(ME.CannotRescueME.selector);
        me.rescueERC1155(address(me), 1, recipient);

        assertEq(me.balanceOf(address(me)), meBefore);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.remainingME(), me.TOTAL_SUPPLY());
    }

    function test_OwnerCanRescueOnlyForeignTokenBalance() public {
        uint256 beforeBalance = foreign.balanceOf(address(me));
        assertEq(beforeBalance, 7 ether);

        me.rescueERC20(address(foreign), recipient);

        assertEq(foreign.balanceOf(address(me)), 0);
        assertEq(foreign.balanceOf(recipient), beforeBalance);
        assertEq(me.reserveMON(), 0);
        assertTrue(me.reserveSolvent());
    }

    function test_ZeroAddressCannotReceiveOwnerFees() public {
        vm.deal(address(me), 1 ether);
        // Forced balance is surplus, not accrued owner fees; establish a
        // real owner-fee liability with a local buy first.
        address buyer = address(0xB0B);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);

        vm.expectRevert(ME.ZeroAddress.selector);
        me.claimOwnerFees(payable(address(0)));
        assertGt(me.accruedOwnerFees(), 0);
        assertTrue(me.reserveSolvent());
    }

    function test_RenounceOwnershipRemainsDisabled() public {
        vm.expectRevert(ME.RenounceDisabled.selector);
        me.renounceOwnership();
        assertEq(me.owner(), address(this));
    }
}
