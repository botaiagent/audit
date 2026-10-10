// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 18: accountingStatus snapshot must match canonical getters.
/// @dev Local Foundry tests and CI only; no live-chain writes.
contract MEAccountingSnapshotGate18Test is Test {
    ME internal me;
    address internal buyer = address(0xB0B);
    address internal recipient = address(0xCAFE);

    function setUp() public {
        me = new ME();
        vm.deal(buyer, 10 ether);
    }

    function _assertSnapshotConsistent() internal view {
        (
            uint256 actualBalance,
            uint256 curveReserve,
            uint256 ownerFeeLiability,
            uint256 surplus,
            uint256 liveK,
            uint256 tokensRemaining,
            bool solvent
        ) = me.accountingStatus();

        assertEq(actualBalance, address(me).balance);
        assertEq(curveReserve, me.reserveMON());
        assertEq(ownerFeeLiability, me.accruedOwnerFees());
        assertEq(surplus, me.surplusMON());
        assertEq(liveK, me.curveK());
        assertEq(tokensRemaining, me.remainingME());
        assertEq(solvent, me.reserveSolvent());
        assertEq(actualBalance, curveReserve + ownerFeeLiability + surplus);
    }

    function test_InitialSnapshotMatchesCanonicalState() public view {
        _assertSnapshotConsistent();
    }

    function test_SnapshotRemainsConsistentAfterBuyAndSell() public {
        vm.prank(buyer);
        me.buyME{value: 2 ether}(0, block.timestamp + 1 days);
        _assertSnapshotConsistent();

        uint256 tokens = me.balanceOf(buyer);
        assertGt(tokens, 0);
        vm.prank(buyer);
        me.sellME(tokens, 0, block.timestamp + 1 days);
        _assertSnapshotConsistent();
    }

    function test_SnapshotSeparatesForcedSurplusFromLiabilities() public {
        vm.prank(buyer);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);

        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        vm.deal(address(me), address(me).balance + 0.25 ether);

        _assertSnapshotConsistent();
        assertEq(me.surplusMON(), 0.25 ether);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);

        me.rescueSurplusMON(recipient);
        _assertSnapshotConsistent();
        assertEq(me.surplusMON(), 0);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
    }
}
