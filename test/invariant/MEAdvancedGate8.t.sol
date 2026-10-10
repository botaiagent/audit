// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ME} from "../../src/ME.sol";

/// @notice Gate 8: stateful invariant campaign and adversarial call sequences.
/// Runs locally/CI only; no RPC calls and no Testnet transactions.
contract MEAdvancedActor {
    ME public immutable me;
    uint256 public lastK;
    uint256 public successfulBuys;
    uint256 public successfulSells;

    constructor(ME target) {
        me = target;
        lastK = target.curveK();
    }

    receive() external payable {}

    function buy(uint96 rawAmount, uint96 rawMinOut) external {
        uint256 amount = boundAmount(rawAmount);
        uint256 minOut = uint256(rawMinOut) % (me.TOTAL_SUPPLY() + 1);
        try me.buyME{value: amount}(minOut, block.timestamp + 1 days) returns (uint256) {
            successfulBuys++;
        } catch {}
        _checkK();
    }

    function sell(uint96 rawAmount, uint96 rawMinOut) external {
        uint256 balance = me.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = uint256(rawAmount) % balance + 1;
        uint256 minOut = uint256(rawMinOut) % (1000 ether + 1);
        try me.sellME(amount, minOut, block.timestamp + 1 days) returns (uint256) {
            successfulSells++;
        } catch {}
        _checkK();
    }

    function adversarial(uint8 choice, uint96 rawAmount) external {
        bool ok;
        uint256 amount = uint256(rawAmount) + 1;
        if (choice % 5 == 0) {
            (ok,) = address(me).call{value: amount}("");
            require(!ok, "direct MON accepted");
        } else if (choice % 5 == 1) {
            (ok,) = address(me).call(
                abi.encodeWithSignature("transfer(address,uint256)", address(me), 1)
            );
            require(!ok, "direct ME transfer accepted");
        } else if (choice % 5 == 2) {
            (ok,) = address(me).call(
                abi.encodeWithSignature("claimOwnerFees(address)", payable(address(this)))
            );
            require(!ok, "unauthorized fee claim accepted");
        } else if (choice % 5 == 3) {
            (ok,) = address(me).call{value: 0.01 ether}(
                abi.encodeWithSignature("buyME(uint256,uint256)", type(uint256).max, block.timestamp + 1 days)
            );
            require(!ok, "impossible minOut accepted");
        } else {
            (ok,) = address(me).call(
                abi.encodeWithSignature("sellME(uint256,uint256,uint256)", me.balanceOf(address(this)), 0, 0)
            );
            require(!ok, "expired sell accepted");
        }
        _checkK();
    }

    function _checkK() internal {
        uint256 currentK = me.curveK();
        require(currentK >= lastK, "curveK decreased");
        lastK = currentK;
    }

    function boundAmount(uint96 raw) internal pure returns (uint256) {
        return (uint256(raw) % (100 ether)) + 0.01 ether;
    }
}

contract MEAdvancedGate8InvariantTest is StdInvariant, Test {
    ME internal me;
    MEAdvancedActor internal actorA;
    MEAdvancedActor internal actorB;

    function setUp() public {
        me = new ME();
        actorA = new MEAdvancedActor(me);
        actorB = new MEAdvancedActor(me);
        vm.deal(address(actorA), 1_000_000 ether);
        vm.deal(address(actorB), 1_000_000 ether);
        targetContract(address(actorA));
        targetContract(address(actorB));
    }

    function invariant_FixedSupplyAndTokenLedgerAlwaysReconcile() public view {
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
        assertEq(me.balanceOf(address(me)), me.remainingME());
        assertEq(me.circulatingME() + me.remainingME(), me.TOTAL_SUPPLY());
    }

    function invariant_ReserveAndOwnerFeeLiabilityRemainSolvent() public view {
        assertTrue(me.reserveSolvent());
        assertGe(address(me).balance, me.reserveMON());
        assertGe(address(me).balance, me.reserveMON() + me.accruedOwnerFees());
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees());
    }

    function invariant_CurveConstantNeverBelowInitial() public view {
        assertGe(me.curveK(), me.INITIAL_K());
    }

    function invariant_ActorsCannotHoldMoreMEThanCirculatingSupply() public view {
        assertLe(me.balanceOf(address(actorA)) + me.balanceOf(address(actorB)), me.circulatingME());
    }
}
