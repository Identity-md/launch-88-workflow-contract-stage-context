// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Handle} from "../src/Handle.sol";
import {NameRegistry} from "../src/NameRegistry.sol";

contract NameRegistryTest is Test {
    Handle token;
    NameRegistry registry;
    address alice = address(0xa);
    address bob = address(0xb);
    address carol = address(0xc);
    uint256 constant YEAR = 365 days;
    uint256 constant FEE = 100 ether;

    function setUp() public {
        token = new Handle();
        registry = new NameRegistry(address(token));
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _fund(address who) internal {
        token.transfer(who, 10000 ether);
        vm.prank(who);
        token.approve(address(registry), type(uint256).max);
    }

    function _register(address who, string memory name) internal {
        vm.prank(who);
        registry.register(name);
    }

    function _renew(address who, string memory name) internal {
        vm.prank(who);
        registry.renew(name);
    }

    function _round() internal {
        vm.warp(registry.nextRoundAt());
        registry.startRound();
        registry.processSnapshot(200);
    }

    function _liveHolders() internal {
        _register(alice, "alice");
        _renew(alice, "alice");
        _register(bob, "bobby");
        _renew(bob, "bobby");
    }

    function testConstructorAndNoETH() public {
        vm.expectRevert(NameRegistry.InvalidToken.selector);
        new NameRegistry(address(0));
        vm.expectRevert(NameRegistry.InvalidToken.selector);
        new NameRegistry(alice);
        (bool ok,) = address(registry).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(registry.token()), address(token));
    }

    function testNameValidation() public {
        string[8] memory invalid =
            [string(""), "ab", "Alice", "abc1", "abc-", "abc_", "abc def", "abcdefghijklmnopqrstuvwxyzabcdefg"];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(NameRegistry.InvalidName.selector);
            registry.register(invalid[i]);
        }
        _register(alice, "abc");
        _register(alice, "abcdefghijklmnopqrstuvwxyzabcdef");
        assertEq(registry.nameCount(), 2);
    }

    function testRegisterRenewTransferExpiryAndReacquire() public {
        uint256 start = block.timestamp;
        _register(alice, "alice");
        (address holder, uint256 expiry) = registry.names(registry.nameId("alice"));
        assertEq(holder, alice);
        assertEq(expiry, start + YEAR);
        vm.expectRevert(NameRegistry.Unavailable.selector);
        registry.register("alice");
        vm.prank(bob);
        vm.expectRevert(NameRegistry.NotHolder.selector);
        registry.renew("alice");
        vm.prank(bob);
        vm.expectRevert(NameRegistry.NotHolder.selector);
        registry.transferName("alice", bob);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.InvalidRecipient.selector);
        registry.transferName("alice", address(0));
        vm.prank(alice);
        vm.expectRevert(NameRegistry.InvalidRecipient.selector);
        registry.transferName("alice", alice);
        vm.warp(start + YEAR - 1);
        _renew(alice, "alice");
        vm.prank(alice);
        registry.transferName("alice", bob);
        (, expiry) = registry.names(registry.nameId("alice"));
        assertEq(expiry, start + 2 * YEAR);
        vm.warp(expiry);
        vm.prank(bob);
        vm.expectRevert(NameRegistry.NotHolder.selector);
        registry.renew("alice");
        vm.prank(bob);
        vm.expectRevert(NameRegistry.NotHolder.selector);
        registry.transferName("alice", alice);
        _register(carol, "alice");
        assertEq(registry.nameCount(), 1);
        assertEq(registry.poolBalance(), 3 * FEE);
    }

    function testWrongAllowanceAndBalanceRollBack() public {
        vm.prank(alice);
        token.approve(address(registry), FEE - 1);
        vm.prank(alice);
        vm.expectRevert(Handle.InsufficientAllowance.selector);
        registry.register("alice");
        vm.prank(address(123));
        token.approve(address(registry), FEE);
        vm.prank(address(123));
        vm.expectRevert(Handle.InsufficientBalance.selector);
        registry.register("alice");
        assertEq(registry.nameCount(), 0);
        assertEq(registry.poolBalance(), 0);
        vm.prank(alice);
        token.approve(address(registry), FEE + 1);
        _register(alice, "alice");
        assertEq(token.allowance(alice, address(registry)), 1);
    }

    function testSnapshotTimingAndFreeze() public {
        _liveHolders();
        vm.expectRevert(NameRegistry.TooEarly.selector);
        registry.startRound();
        vm.expectRevert(NameRegistry.NoSnapshot.selector);
        registry.processSnapshot(1);
        vm.warp(registry.nextRoundAt());
        registry.startRound();
        vm.expectRevert(NameRegistry.InvalidBatch.selector);
        registry.processSnapshot(0);
        vm.expectRevert(NameRegistry.InvalidBatch.selector);
        registry.processSnapshot(201);
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.register("carol");
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.renew("alice");
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.transferName("alice", bob);
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.claim("alice");
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.startRound();
        registry.processSnapshot(1);
        assertTrue(registry.snapshotting());
        vm.prank(carol);
        registry.processSnapshot(1);
        assertFalse(registry.snapshotting());
        assertEq(registry.holderCount(), 2);
    }

    function testEqualSharesUniqueHoldersAndConservation() public {
        _liveHolders();
        _register(alice, "other");
        _renew(alice, "other");
        _round();
        assertEq(registry.holderCount(), 2);
        assertEq(registry.share(), 3 * FEE);
        uint256 a = token.balanceOf(alice);
        uint256 b = token.balanceOf(bob);
        vm.prank(bob);
        registry.claim("bobby");
        vm.prank(alice);
        registry.claim("alice");
        assertEq(token.balanceOf(alice) - a, token.balanceOf(bob) - b);
        assertEq(registry.poolBalance(), 0);
        assertEq(token.balanceOf(address(registry)), 0);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.AlreadyClaimed.selector);
        registry.claim("other");
    }

    function testLateEntryTransferAndCurrentHolderProof() public {
        _liveHolders();
        _round();
        _register(carol, "carol");
        vm.prank(carol);
        vm.expectRevert(NameRegistry.NotEligible.selector);
        registry.claim("carol");
        vm.prank(alice);
        registry.transferName("alice", carol);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NotHolder.selector);
        registry.claim("alice");
        vm.prank(carol);
        vm.expectRevert(NameRegistry.NotEligible.selector);
        registry.claim("alice");
        vm.prank(carol);
        registry.transferName("alice", alice);
        vm.prank(alice);
        registry.claim("alice");
        vm.prank(alice);
        registry.transferName("alice", bob);
        vm.prank(bob);
        registry.claim("alice");
        vm.prank(bob);
        vm.expectRevert(NameRegistry.AlreadyClaimed.selector);
        registry.claim("bobby");
        assertEq(registry.poolBalance(), FEE);
    }

    function testExpiredSnapshotAndEmptyRound() public {
        _register(alice, "alice");
        _round();
        assertEq(registry.holderCount(), 0);
        assertEq(registry.share(), 0);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NotHolder.selector);
        registry.claim("alice");
        _register(alice, "alice");
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NotEligible.selector);
        registry.claim("alice");
        NameRegistry empty = new NameRegistry(address(token));
        vm.warp(empty.nextRoundAt());
        empty.startRound();
        empty.processSnapshot(1);
        assertFalse(empty.snapshotting());
    }

    function testUnclaimedAndRoundingRollOverAndClaimAgain() public {
        _liveHolders();
        _round();
        vm.prank(alice);
        registry.claim("alice");
        _renew(alice, "alice");
        _renew(bob, "bobby");
        _round();
        assertEq(registry.share(), 2 * FEE);
        vm.prank(alice);
        registry.claim("alice");
        vm.prank(bob);
        registry.claim("bobby");
        assertEq(registry.poolBalance(), 0);
    }

    function testRoundingAndDonationAreNotOverpaid() public {
        _liveHolders();
        _register(carol, "carol");
        _renew(carol, "carol");
        _renew(alice, "alice");
        token.transfer(address(registry), 17);
        _round();
        uint256 expected = 7 * FEE / 3;
        assertEq(registry.share(), expected);
        vm.prank(alice);
        registry.claim("alice");
        vm.prank(bob);
        registry.claim("bobby");
        vm.prank(carol);
        registry.claim("carol");
        assertEq(registry.poolBalance(), 7 * FEE % 3);
        assertEq(token.balanceOf(address(registry)), registry.poolBalance() + 17);
    }

    function testFuzzPoolConservation(uint8 renewals, bool reverse) public {
        renewals = uint8(bound(renewals, 1, 30));
        _liveHolders();
        for (uint256 i; i < renewals; ++i) {
            _renew(alice, "alice");
        }
        _round();
        uint256 share = registry.share();
        vm.prank(reverse ? bob : alice);
        registry.claim(reverse ? "bobby" : "alice");
        vm.prank(reverse ? alice : bob);
        registry.claim(reverse ? "alice" : "bobby");
        assertEq(registry.poolBalance() + 2 * share, (4 + uint256(renewals)) * FEE);
        assertEq(token.balanceOf(address(registry)), registry.poolBalance());
    }

    function testLargeSnapshotRequiresMultipleBoundedCalls() public {
        for (uint256 i; i < 201; ++i) {
            string memory name =
                string(abi.encodePacked(bytes1(0x61), bytes1(uint8(0x61 + i / 26)), bytes1(uint8(0x61 + i % 26))));
            token.transfer(alice, FEE * 2);
            _register(alice, name);
            _renew(alice, name);
        }
        vm.warp(registry.nextRoundAt());
        registry.startRound();
        registry.processSnapshot(200);
        assertTrue(registry.snapshotting());
        assertEq(registry.snapshotCursor(), 200);
        registry.processSnapshot(200);
        assertFalse(registry.snapshotting());
        assertEq(registry.holderCount(), 1);
        assertEq(registry.share(), 402 * FEE);
        vm.prank(alice);
        registry.claim("aaa");
        assertEq(registry.poolBalance(), 0);
    }
}
