// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Handle} from "../src/Handle.sol";

contract HandleTest is Test {
    Handle token;
    address alice = address(0xa);
    address bob = address(0xb);

    function setUp() public {
        token = new Handle();
    }

    function testMetadataAndSupply() public view {
        assertEq(token.name(), "Handle");
        assertEq(token.symbol(), "HNDL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzzTransferConservation(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice), token.totalSupply());
        vm.prank(alice);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
    }

    function testAllowanceFiniteInfiniteAndRevocation() public {
        token.approve(alice, 10);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 4);
        assertEq(token.allowance(address(this), alice), 6);
        token.approve(alice, 0);
        vm.prank(alice);
        vm.expectRevert(Handle.InsufficientAllowance.selector);
        token.transferFrom(address(this), bob, 1);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 100);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function testInvalidTransfersAndApproval() public {
        vm.expectRevert(Handle.ZeroAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(Handle.ZeroAddress.selector);
        token.approve(address(0), 1);
        vm.prank(alice);
        vm.expectRevert(Handle.InsufficientBalance.selector);
        token.transfer(bob, 1);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(Handle.InsufficientBalance.selector);
        token.transferFrom(address(this), bob, 1e27 + 1);
    }

    function testNoMintOrAdmin() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("transferOwnership(address)", alice));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }
}
