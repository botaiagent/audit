// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ME} from "../../src/ME.sol";

contract MEActor {
    ME public immutable me;
    constructor(ME target) { me = target; }
    receive() external payable {}

    function buy(uint256 rawAmount) external {
        uint256 amount = rawAmount % (100 ether) + 0.01 ether;
        try me.buyME{value: amount}(0, block.timestamp + 1 days) returns (uint256) {} catch {}
    }

    function sell(uint256 rawAmount) external {
        uint256 bal = me.balanceOf(address(this));
        if (bal == 0) return;
        uint256 amount = rawAmount % bal + 1;
        try me.sellME(amount, 0, block.timestamp + 1 days) returns (uint256) {} catch {}
    }
}

contract MEInvariantTest is StdInvariant, Test {
    ME internal me;
    MEActor internal actorA;
    MEActor internal actorB;

    function setUp() public {
        me = new ME();
        actorA = new MEActor(me);
        actorB = new MEActor(me);
        vm.deal(address(actorA), 1_000_000 ether);
        vm.deal(address(actorB), 1_000_000 ether);
        targetContract(address(actorA));
        targetContract(address(actorB));
    }

    function invariant_TotalSupplyNeverChanges() public view {
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
    }

    function invariant_ContractTokenBalanceEqualsRemaining() public view {
        assertEq(me.balanceOf(address(me)), me.remainingME());
        assertLe(me.remainingME(), me.TOTAL_SUPPLY());
    }

    function invariant_ReserveIsSolvent() public view {
        assertTrue(me.reserveSolvent());
        assertGe(address(me).balance, me.reserveMON());
    }

    function invariant_CirculatingPlusRemainingEqualsSupply() public view {
        assertEq(me.circulatingME() + me.remainingME(), me.TOTAL_SUPPLY());
    }
}
