// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @notice Gate 12: adversarial rescue paths and external-token edge cases.
/// @dev Local Foundry tests only. No RPC writes or deployments.
contract MEAdversarialRescueGate12Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);
    address internal recipient = address(0xBEEF);

    function setUp() public {
        me = new ME();
    }

    function test_RescueERC721PreservesCurveAccounting() public {
        TestNFT nft = new TestNFT();
        nft.mint(address(me), 7);
        uint256 reserveBefore = me.reserveMON();
        uint256 kBefore = me.curveK();

        me.rescueERC721(address(nft), 7, recipient);

        assertEq(nft.ownerOf(7), recipient);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.curveK(), kBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_RescueERC1155PreservesCurveAccounting() public {
        TestMultiToken token = new TestMultiToken();
        token.mint(address(me), 42, 9);
        uint256 reserveBefore = me.reserveMON();
        uint256 kBefore = me.curveK();

        me.rescueERC1155(address(token), 42, recipient);

        assertEq(token.balanceOf(recipient, 42), 9);
        assertEq(token.balanceOf(address(me), 42), 0);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.curveK(), kBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_NonOwnerCannotRescueNFTOrMultiToken() public {
        TestNFT nft = new TestNFT();
        TestMultiToken token = new TestMultiToken();
        nft.mint(address(me), 1);
        token.mint(address(me), 2, 3);

        vm.prank(alice);
        vm.expectRevert();
        me.rescueERC721(address(nft), 1, recipient);

        vm.prank(alice);
        vm.expectRevert();
        me.rescueERC1155(address(token), 2, recipient);

        assertEq(nft.ownerOf(1), address(me));
        assertEq(token.balanceOf(address(me), 2), 3);
    }

    function test_RescueNFTRejectsZeroAndNonContractAddresses() public {
        TestNFT nft = new TestNFT();
        nft.mint(address(me), 3);

        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueERC721(address(nft), 3, address(0));

        vm.expectRevert(ME.InvalidTokenContract.selector);
        me.rescueERC721(address(0x1234), 3, recipient);

        vm.expectRevert(ME.InvalidTokenContract.selector);
        me.rescueERC1155(address(0x1234), 1, recipient);
    }

    function test_RescueForeignERC20DoesNotTouchMEOrReserve() public {
        TestToken token = new TestToken();
        token.mint(address(me), 1234);
        uint256 meBefore = me.balanceOf(address(me));
        uint256 reserveBefore = me.reserveMON();
        uint256 kBefore = me.curveK();

        me.rescueERC20(address(token), recipient);

        assertEq(token.balanceOf(recipient), 1234);
        assertEq(me.balanceOf(address(me)), meBefore);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.curveK(), kBefore);
        assertTrue(me.reserveSolvent());
    }

    function testFuzz_RescueERC20AmountDoesNotAffectCurve(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, type(uint96).max);
        TestToken token = new TestToken();
        token.mint(address(me), amount);
        uint256 reserveBefore = me.reserveMON();
        uint256 remainingBefore = me.remainingME();
        uint256 kBefore = me.curveK();

        me.rescueERC20(address(token), recipient);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.remainingME(), remainingBefore);
        assertEq(me.curveK(), kBefore);
        assertTrue(me.reserveSolvent());
    }
}

contract TestToken is ERC20 {
    constructor() ERC20("Foreign", "FOR") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract TestNFT is ERC721 {
    constructor() ERC721("Foreign NFT", "FNFT") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract TestMultiToken is ERC1155 {
    constructor() ERC1155("") {}
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}
