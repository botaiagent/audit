// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MEAdversarialGate6Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 100 ether);
    }

    function _buyOneMON() internal {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
    }

    function test_FailedOwnerFeePayoutRollsBackLiability() public {
        _buyOneMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 reserveBefore = me.reserveMON();
        uint256 balanceBefore = address(me).balance;
        RejectNativeReceiver rejector = new RejectNativeReceiver();

        vm.expectRevert(ME.MONTransferFailed.selector);
        me.claimOwnerFees(payable(address(rejector)));

        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(address(me).balance, balanceBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_FailedSurplusPayoutRollsBackAndCannotTouchReserve() public {
        _buyOneMON();
        vm.deal(address(me), address(me).balance + 0.25 ether);
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 surplusBefore = me.surplusMON();
        RejectNativeReceiver rejector = new RejectNativeReceiver();

        vm.expectRevert(ME.MONTransferFailed.selector);
        me.rescueSurplusMON(address(rejector));

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.surplusMON(), surplusBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_OnlyOwnerCanRescueForeignERC20() public {
        MockForeignToken foreign = new MockForeignToken();
        foreign.mint(address(me), 123 ether);

        vm.prank(alice);
        vm.expectRevert();
        me.rescueERC20(address(foreign), alice);

        me.rescueERC20(address(foreign), alice);
        assertEq(foreign.balanceOf(alice), 123 ether);
        assertEq(foreign.balanceOf(address(me)), 0);
    }

    function test_CannotRescueUnrelatedContractAsERC20() public {
        vm.expectRevert(ME.InvalidTokenContract.selector);
        me.rescueERC20(address(0x1234), alice);
    }

    function test_DirectNativeTransfersRemainBlocked() public {
        (bool okReceive,) = address(me).call{value: 1 wei}("");
        assertFalse(okReceive);

        (bool okFallback,) = address(me).call{value: 1 wei}(hex"12345678");
        assertFalse(okFallback);

        assertEq(me.reserveMON(), 0);
        assertEq(me.accruedOwnerFees(), 0);
        assertTrue(me.reserveSolvent());
    }

    function test_FailedSellPayoutRollsBackTokenAndCurveState() public {
        RejectNativeReceiver rejector = new RejectNativeReceiver();
        vm.deal(address(rejector), 2 ether);
        rejector.buyFrom(address(me), 1 ether);

        uint256 tokenBalanceBefore = me.balanceOf(address(rejector));
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 kBefore = me.curveK();
        uint256 contractBalanceBefore = address(me).balance;

        vm.expectRevert(ME.MONTransferFailed.selector);
        rejector.sellAll(address(me));

        assertEq(me.balanceOf(address(rejector)), tokenBalanceBefore);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(address(me).balance, contractBalanceBefore);
        assertTrue(me.reserveSolvent());
    }
}

contract RejectNativeReceiver {
    function buyFrom(address token, uint256 amount) external {
        (bool ok, bytes memory data) = token.call{value: amount}(
            abi.encodeWithSignature("buyME(uint256,uint256)", 0, block.timestamp + 1 days)
        );
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(data, 32), mload(data))
            }
        }
    }

    function sellAll(address token) external {
        uint256 amount = IERC20Like(token).balanceOf(address(this));
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("sellME(uint256,uint256,uint256)", amount, 0, block.timestamp + 1 days)
        );
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(data, 32), mload(data))
            }
        }
    }

    receive() external payable {
        revert("reject native coin");
    }
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

contract MockForeignToken is ERC20 {
    constructor() ERC20("Foreign", "FOR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
