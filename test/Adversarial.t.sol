// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {NameRegistry} from "../src/NameRegistry.sol";
import {Handle} from "../src/Handle.sol";

contract HostileToken {
    mapping(address => uint256) public balanceOf;
    uint256 public mode;
    NameRegistry public registry;
    uint256 public blockedCallbacks;

    function configure(NameRegistry target, uint256 mode_) external {
        registry = target;
        mode = mode_;
    }

    function fund(address who, uint256 amount) external {
        balanceOf[who] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return _move(from, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        if (mode == 1) return false;
        if (mode == 2) revert("hostile revert");
        if (mode == 4) {
            bytes[6] memory calls = [
                abi.encodeCall(NameRegistry.register, ("evil")),
                abi.encodeCall(NameRegistry.renew, ("alice")),
                abi.encodeCall(NameRegistry.transferName, ("alice", address(1))),
                abi.encodeCall(NameRegistry.startRound, ()),
                abi.encodeCall(NameRegistry.processSnapshot, (1)),
                abi.encodeCall(NameRegistry.claim, ("alice"))
            ];
            for (uint256 i; i < calls.length; ++i) {
                (bool ok, bytes memory data) = address(registry).call(calls[i]);
                require(
                    !ok && keccak256(data) == keccak256(abi.encodeWithSelector(NameRegistry.Reentrancy.selector)),
                    "unguarded callback"
                );
                ++blockedCallbacks;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += mode == 3 ? amount - 1 : amount;
        return true;
    }
}

contract AdversarialTest is Test {
    HostileToken token;
    NameRegistry registry;
    address alice = address(0xa);

    function setUp() public {
        token = new HostileToken();
        registry = new NameRegistry(address(token));
        token.fund(alice, 10000 ether);
        token.configure(registry, 0);
    }

    function testRejectedCollectionsRollbackEveryEffect() public {
        for (uint256 mode = 1; mode <= 3; ++mode) {
            token.configure(registry, mode);
            vm.prank(alice);
            vm.expectRevert();
            registry.register("alice");
            assertEq(registry.nameCount(), 0);
            assertEq(registry.poolBalance(), 0);
            (address holder, uint256 expiry) = registry.names(keccak256("alice"));
            assertEq(holder, address(0));
            assertEq(expiry, 0);
        }
        token.configure(registry, 0);
        vm.prank(alice);
        registry.register("alice");
        (, uint256 originalExpiry) = registry.names(keccak256("alice"));
        token.configure(registry, 1);
        vm.prank(alice);
        vm.expectRevert();
        registry.renew("alice");
        (, uint256 expiryAfter) = registry.names(keccak256("alice"));
        assertEq(expiryAfter, originalExpiry);
        assertEq(registry.poolBalance(), registry.FEE());
    }

    function _ready() internal {
        vm.prank(alice);
        registry.register("alice");
        vm.prank(alice);
        registry.renew("alice");
        vm.warp(registry.nextRoundAt());
        registry.startRound();
        registry.processSnapshot(1);
    }

    function testRejectedPayoutRetainsClaimAndFundsForRetry() public {
        _ready();
        uint256 pool = registry.poolBalance();
        for (uint256 mode = 1; mode <= 3; ++mode) {
            token.configure(registry, mode);
            vm.prank(alice);
            vm.expectRevert();
            registry.claim("alice");
            assertEq(registry.claimedRound(alice), 0);
            assertEq(registry.poolBalance(), pool);
            assertEq(token.balanceOf(address(registry)), pool);
        }
        token.configure(registry, 0);
        vm.prank(alice);
        registry.claim("alice");
        assertEq(registry.poolBalance(), 0);
    }

    function testReentrancyBlockedOnRegistrationRenewalAndClaim() public {
        token.configure(registry, 4);
        _ready();
        assertEq(token.blockedCallbacks(), 12);
        vm.prank(alice);
        registry.claim("alice");
        assertEq(token.blockedCallbacks(), 18);
        assertEq(registry.poolBalance(), 0);
        assertEq(registry.nameCount(), 1);
    }

    function testExpiryDuringSnapshotUsesFrozenTimeButClaimNeedsLiveName() public {
        vm.prank(alice);
        registry.register("alice");
        vm.warp(block.timestamp + 1);
        token.fund(address(2), 1000 ether);
        vm.prank(address(2));
        registry.register("bobby");
        vm.warp(registry.nextRoundAt());
        registry.startRound();
        registry.processSnapshot(1);
        vm.warp(block.timestamp + 1);
        registry.processSnapshot(1);
        assertEq(registry.holderCount(), 1);
        vm.prank(address(2));
        vm.expectRevert(NameRegistry.NotHolder.selector);
        registry.claim("bobby");
        vm.prank(address(2));
        registry.register("bobby");
        vm.prank(address(2));
        registry.claim("bobby");
        assertEq(registry.poolBalance(), registry.FEE());
    }

    function testRuntimeOpcodeFloor() public {
        Handle handle = new Handle();
        _check(address(handle).code);
        _check(address(registry).code);
    }

    function _check(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}
