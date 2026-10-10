// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @dev Contract trader attempts to re-enter sellME during MON payout.
contract Gate17ReentrantSeller {
    ME public immutable me;
    bool public attemptReentry;
    bool public reentrySucceeded;
    uint256 public reentryAmount;

    constructor(ME token) {
        me = token;
    }

    function buy(uint256 value) external payable {
        me.buyME{value: value}(0, block.timestamp + 1 days);
    }

    function sellAll() external {
        uint256 amount = me.balanceOf(address(this));
        me.sellME(amount, 0, block.timestamp + 1 days);
    }

    receive() external payable {
        if (attemptReentry) {
            attemptReentry = false;
            reentryAmount = me.balanceOf(address(this));
            (reentrySucceeded,) = address(me).call(
                abi.encodeWithSelector(
                    ME.sellME.selector,
                    reentryAmount,
                    0,
                    block.timestamp + 1 days
                )
            );
        }
    }

    function enableReentry() external {
        attemptReentry = true;
    }
}

/// @notice Gate 17: reentrancy resistance at native-MON payout boundaries.
/// @dev Local Foundry tests and CI only; no live-chain writes.
contract MEReentrancyBoundaryGate17Test is Test {
    ME internal me;
    Gate17ReentrantSeller internal seller;

    function setUp() public {
        me = new ME();
        seller = new Gate17ReentrantSeller(me);
        vm.deal(address(this), 20 ether);
        seller.buy{value: 5 ether}(5 ether);
    }

    function test_SellPayoutCannotReenterSellME() public {
        uint256 tokens = me.balanceOf(address(seller));
        assertGt(tokens, 0);
        seller.enableReentry();

        uint256 reserveBefore = me.reserveMON();
        seller.sellAll();

        assertFalse(seller.reentrySucceeded(), "reentrant sell unexpectedly succeeded");
        assertEq(me.balanceOf(address(seller)), 0);
        assertLt(me.reserveMON(), reserveBefore);
        assertTrue(me.reserveSolvent());
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees());
    }

    function test_ReentrantAttemptDoesNotBlockLegitimateSell() public {
        seller.enableReentry();
        uint256 monBefore = address(seller).balance;
        uint256 tokens = me.balanceOf(address(seller));
        uint256 quoted = me.quoteSellFor(address(seller), tokens);

        seller.sellAll();

        assertFalse(seller.reentrySucceeded());
        assertEq(address(seller).balance - monBefore, quoted);
        assertEq(me.balanceOf(address(seller)), 0);
        assertTrue(me.reserveSolvent());
    }

    function test_ForcedMONSurplusRemainsSeparateFromCurveLiabilities() public {
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        vm.deal(address(me), address(me).balance + 1 ether);

        assertEq(me.surplusMON(), 1 ether);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertTrue(me.reserveSolvent());

        uint256 ownerBefore = address(this).balance;
        me.rescueSurplusMON(address(this));
        assertEq(address(this).balance - ownerBefore, 1 ether);
        assertEq(me.surplusMON(), 0);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertTrue(me.reserveSolvent());
    }
}
