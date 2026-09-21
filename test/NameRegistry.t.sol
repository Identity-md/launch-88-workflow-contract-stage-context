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
        while (registry.snapshotting()) {
            registry.processSnapshot(200);
        }
    }

    function _liveHolders() internal {
        _register(alice, "alice");
        _renew(alice, "alice");
        _register(bob, "bobby");
        _renew(bob, "bobby");
    }

    /// @dev The frontend rebuilds "my names" from these logs, so topics and payloads are asserted
    /// exactly: a swapped from/to or a wrong expiry is a wrong website, not just a cosmetic defect.
    function testLeaseEventsCarryExactTopicsAndPayloads() public {
        uint256 start = block.timestamp;
        bytes32 id = registry.nameId("alice");
        vm.expectEmit(true, true, false, true, address(registry));
        emit NameRegistry.Registered(id, "alice", alice, start + YEAR);
        _register(alice, "alice");
        vm.expectEmit(true, false, false, true, address(registry));
        emit NameRegistry.Renewed(id, start + 2 * YEAR);
        _renew(alice, "alice");
        vm.expectEmit(true, true, true, true, address(registry));
        emit NameRegistry.NameTransferred(id, alice, bob);
        vm.prank(alice);
        registry.transferName("alice", bob);
        vm.warp(start + 2 * YEAR);
        vm.expectEmit(true, true, false, true, address(registry));
        emit NameRegistry.Registered(id, "alice", carol, start + 3 * YEAR);
        _register(carol, "alice");
    }

    function testDistributionEventsCarryExactTopicsAndPayloads() public {
        _liveHolders();
        uint256 at = registry.nextRoundAt();
        vm.warp(at);
        vm.expectEmit(true, false, false, true, address(registry));
        emit NameRegistry.RoundStarted(1, at, 4 * FEE);
        vm.expectEmit(true, false, false, true, address(registry));
        emit NameRegistry.SnapshotProgress(1, 2, 2);
        vm.expectEmit(true, false, false, true, address(registry));
        emit NameRegistry.RoundReady(1, 2, 2 * FEE);
        registry.startRound();
        vm.expectEmit(true, true, false, true, address(registry));
        emit NameRegistry.Claimed(1, alice, 2 * FEE);
        vm.prank(alice);
        registry.claim();
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
        vm.prank(alice);
        vm.expectRevert(NameRegistry.InvalidRecipient.selector);
        registry.transferName("alice", address(registry));
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

    function testSnapshotTimingAndSmallRegistrySettlesInOneCall() public {
        _liveHolders();
        vm.expectRevert(NameRegistry.TooEarly.selector);
        registry.startRound();
        vm.expectRevert(NameRegistry.NoSnapshot.selector);
        registry.processSnapshot(1);
        vm.warp(registry.nextRoundAt());
        registry.startRound();
        assertFalse(registry.snapshotting());
        assertEq(registry.holderCount(), 2);
        assertEq(registry.share(), 2 * FEE);
        vm.expectRevert(NameRegistry.NoSnapshot.selector);
        registry.processSnapshot(1);
        vm.expectRevert(NameRegistry.TooEarly.selector);
        registry.startRound();
        _register(carol, "carol");
    }

    /// @dev A registry with no names must not be left frozen waiting for an unpaid volunteer.
    function testEmptyRegistryRoundNeedsNoSecondTransaction() public {
        vm.warp(registry.nextRoundAt());
        vm.prank(carol);
        registry.startRound();
        assertFalse(registry.snapshotting());
        assertEq(registry.round(), 1);
        assertEq(registry.holderCount(), 0);
        assertEq(registry.share(), 0);
        _register(alice, "alice");
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
        registry.claim();
        vm.prank(alice);
        registry.claim();
        assertEq(token.balanceOf(alice) - a, token.balanceOf(bob) - b);
        assertEq(registry.poolBalance(), 0);
        assertEq(token.balanceOf(address(registry)), 0);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.AlreadyClaimed.selector);
        registry.claim();
    }

    /// @dev Entitlement belongs to the snapshot address: giving a name away neither moves the share
    /// nor strands it, and a late entrant waits for the next snapshot rather than sharing this one.
    function testLateEntryAndTransferLeaveNoShareStranded() public {
        _liveHolders();
        _round();
        assertEq(registry.share(), 2 * FEE);
        _register(carol, "carol");
        vm.prank(carol);
        vm.expectRevert(NameRegistry.NotEligible.selector);
        registry.claim();
        vm.prank(alice);
        registry.transferName("alice", carol);
        vm.prank(alice);
        registry.claim();
        vm.prank(carol);
        vm.expectRevert(NameRegistry.NotEligible.selector);
        registry.claim();
        vm.prank(bob);
        registry.claim();
        vm.prank(bob);
        vm.expectRevert(NameRegistry.AlreadyClaimed.selector);
        registry.claim();
        assertEq(registry.poolBalance(), FEE);
        assertEq(token.balanceOf(address(registry)), FEE);
        _renew(carol, "carol");
        _renew(bob, "bobby");
        _round();
        assertEq(registry.round(), 2);
        assertEq(registry.holderCount(), 2);
        assertEq(registry.share(), 3 * FEE / 2);
        vm.prank(carol);
        registry.claim();
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NotEligible.selector);
        registry.claim();
    }

    function testExpiredAtSnapshotEarnsNothing() public {
        _register(alice, "alice");
        _round();
        assertEq(registry.holderCount(), 0);
        assertEq(registry.share(), 0);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NotEligible.selector);
        registry.claim();
        _register(alice, "alice");
        vm.prank(alice);
        vm.expectRevert(NameRegistry.NotEligible.selector);
        registry.claim();
        assertEq(registry.poolBalance(), 2 * FEE);
    }

    function testUnclaimedAndRoundingRollOverAndClaimAgain() public {
        _liveHolders();
        _round();
        vm.prank(alice);
        registry.claim();
        _renew(alice, "alice");
        _renew(bob, "bobby");
        _round();
        assertEq(registry.share(), 2 * FEE);
        vm.prank(alice);
        registry.claim();
        vm.prank(bob);
        registry.claim();
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
        registry.claim();
        vm.prank(bob);
        registry.claim();
        vm.prank(carol);
        registry.claim();
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
        registry.claim();
        vm.prank(reverse ? alice : bob);
        registry.claim();
        assertEq(registry.poolBalance() + 2 * share, (4 + uint256(renewals)) * FEE);
        assertEq(token.balanceOf(address(registry)), registry.poolBalance());
    }

    /// @dev Beyond one batch the snapshot spans transactions, which is the only state in which name
    /// operations are frozen. Renewal stays open there on purpose; see testRenewalSurvivesAnAttacker.
    function testLargeSnapshotFreezesEverythingExceptRenewal() public {
        for (uint256 i; i < 201; ++i) {
            string memory name =
                string(abi.encodePacked(bytes1(0x61), bytes1(uint8(0x61 + i / 26)), bytes1(uint8(0x61 + i % 26))));
            token.transfer(alice, FEE * 2);
            _register(alice, name);
            _renew(alice, name);
        }
        vm.warp(registry.nextRoundAt());
        registry.startRound();
        assertTrue(registry.snapshotting());
        assertEq(registry.snapshotCursor(), 200);
        vm.expectRevert(NameRegistry.InvalidBatch.selector);
        registry.processSnapshot(0);
        vm.expectRevert(NameRegistry.InvalidBatch.selector);
        registry.processSnapshot(201);
        vm.prank(bob);
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.register("bobby");
        vm.prank(alice);
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.transferName("aaa", bob);
        vm.prank(alice);
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.claim();
        vm.expectRevert(NameRegistry.SnapshotInProgress.selector);
        registry.startRound();
        token.transfer(alice, FEE);
        _renew(alice, "aaa");
        vm.prank(carol);
        registry.processSnapshot(200);
        assertFalse(registry.snapshotting());
        assertEq(registry.holderCount(), 1);
        assertEq(registry.share(), 402 * FEE);
        vm.prank(alice);
        registry.claim();
        assertEq(registry.poolBalance(), FEE);
    }

    /// @dev Regression: a permissionless startRound() must not be usable to hold renew() shut across
    /// a lease's expiry and take the name. The freeze is timed by the attacker, so renewal cannot be
    /// part of it. Renewing mid-snapshot cannot change membership either: the lease is live now, so
    /// it was already live at the earlier snapshotAt, and the holder does not change.
    function testRenewalSurvivesAnAttackerTimedRoundStart() public {
        uint256 start = block.timestamp;
        _register(alice, "alice");
        _renew(alice, "alice");
        for (uint256 i; i < 200; ++i) {
            string memory name =
                string(abi.encodePacked(bytes1(0x7a), bytes1(uint8(0x61 + i / 26)), bytes1(uint8(0x61 + i % 26))));
            token.transfer(bob, FEE);
            _register(bob, name);
        }
        vm.warp(start + 2 * YEAR - 12);
        vm.prank(carol);
        registry.startRound();
        assertTrue(registry.snapshotting());
        _renew(alice, "alice");
        (, uint256 expiry) = registry.names(registry.nameId("alice"));
        assertEq(expiry, start + 3 * YEAR);
        vm.warp(start + 2 * YEAR);
        registry.processSnapshot(200);
        assertFalse(registry.snapshotting());
        (address holder,) = registry.names(registry.nameId("alice"));
        assertEq(holder, alice);
        vm.prank(carol);
        vm.expectRevert(NameRegistry.Unavailable.selector);
        registry.register("alice");
        assertEq(registry.eligibleRound(alice), registry.round());
        vm.prank(alice);
        registry.claim();
    }
}
