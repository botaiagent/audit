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

    /// @notice Randomized adversarial calls; each selected exploit attempt must fail.
    function attack(uint256 selector, uint256 rawAmount) external {
        uint256 choice = selector % 6;
        bool ok;
        bytes memory data;

        if (choice == 0) {
            (ok,) = address(me).call{value: (rawAmount % 1 ether) + 1}("");
            require(!ok, "direct MON accepted");
        } else if (choice == 1) {
            (ok, data) = address(me).call(
                abi.encodeWithSignature("transfer(address,uint256)", address(me), 1)
            );
            require(!ok, "direct ME transfer accepted");
        } else if (choice == 2) {
            (ok,) = address(me).call(
                abi.encodeWithSignature("claimOwnerFees(address)", payable(address(this)))
            );
            require(!ok, "unauthorized fee claim accepted");
        } else if (choice == 3) {
            (ok,) = address(me).call(
                abi.encodeWithSignature("rescueSurplusMON(address)", address(this))
            );
            require(!ok, "unauthorized surplus rescue accepted");
        } else if (choice == 4) {
            (ok,) = address(me).call{value: 0.01 ether}(
                abi.encodeWithSignature("buyME(uint256,uint256)", type(uint256).max, 0)
            );
            require(!ok, "slippage/deadline attack accepted");
        } else {
            uint256 bal = me.balanceOf(address(this));
            if (bal > 0) {
                (ok,) = address(me).call(
                    abi.encodeWithSignature("sellME(uint256,uint256,uint256)", bal, 0, 0)
                );
                require(!ok, "expired sell accepted");
            }
        }
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
