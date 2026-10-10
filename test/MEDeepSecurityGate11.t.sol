// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 11: callback/reentrancy and hostile-recipient stress tests.
/// @dev Foundry local tests only. No RPC calls, private keys, or Testnet transactions.
contract MEDeepSecurityGate11Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);
    address internal feeSink = address(0xFEE);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 25 ether);
    }

    function test_SellPayoutCallbackCannotReenterBuy() public {
        ReenterOnReceive attacker = new ReenterOnReceive(me);
        vm.deal(address(attacker), 1 ether);
        attacker.buy{value: 1 ether}();
        uint256 tokens = me.balanceOf(address(attacker));
        assertGt(tokens, 0);
        attacker.arm();
        attacker.sell(tokens);

        assertTrue(attacker.callbackTriggered(), "sell payout callback not triggered");
        assertFalse(attacker.reentrySucceeded(), "reentrant buy unexpectedly succeeded");
        assertEq(me.balanceOf(address(attacker)), 0, "seller should exit position");
        assertTrue(me.reserveSolvent(), "liabilities insolvent after callback");
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees() + me.surplusMON());
    }

    function test_FeeClaimCallbackCannotReenterOwnerClaim() public {
        me.buyME{value: 2 ether}(0, block.timestamp + 1 days);
        uint256 feeBefore = me.accruedOwnerFees();
        assertGt(feeBefore, 0);

        ReenterOnReceive receiver = new ReenterOnReceive(me);
        receiver.arm();
        me.claimOwnerFees(payable(address(receiver)));

        assertTrue(receiver.callbackTriggered(), "fee callback not triggered");
        assertFalse(receiver.reentrySucceeded(), "reentrant buy unexpectedly succeeded");
        assertEq(me.accruedOwnerFees(), 0, "fee liability should be cleared");
        assertEq(address(receiver).balance, feeBefore, "receiver should get exact fee once");
        assertTrue(me.reserveSolvent(), "liabilities insolvent after claim");
    }

    function test_ContractBuyerCanSellAndAccountingRemainsConsistent() public {
        ReenterOnReceive trader = new ReenterOnReceive(me);
        vm.deal(address(trader), 2 ether);
        trader.buy{value: 1 ether}();
        uint256 amount = me.balanceOf(address(trader));
        trader.sell(amount);
        assertEq(me.balanceOf(address(trader)), 0);
        assertTrue(me.reserveSolvent());
        assertEq(me.balanceOf(address(me)), me.remainingME());
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
    }

    function testFuzz_ClaimFeesNeverChangesCurveReserve(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 20 ether);
        vm.prank(alice);
        me.buyME{value: amount}(0, block.timestamp + 1 days);
        uint256 reserveBefore = me.reserveMON();
        uint256 feeBefore = me.accruedOwnerFees();
        assertGt(feeBefore, 0);
        me.claimOwnerFees(payable(feeSink));
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), 0);
        assertEq(feeSink.balance, feeBefore);
        assertTrue(me.reserveSolvent());
    }
}

contract ReenterOnReceive {
    ME public immutable me;
    bool public armed;
    bool public callbackTriggered;
    bool public reentrySucceeded;

    constructor(ME target) {
        me = target;
    }

    function buy() external payable {
        me.buyME{value: msg.value}(0, block.timestamp + 1 days);
    }

    function sell(uint256 amount) external {
        me.sellME(amount, 0, block.timestamp + 1 days);
    }

    function arm() external {
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        callbackTriggered = true;
        (bool ok,) = address(me).call{value: 0.01 ether}(
            abi.encodeCall(ME.buyME, (0, block.timestamp + 1 days))
        );
        reentrySucceeded = ok;
    }
}
