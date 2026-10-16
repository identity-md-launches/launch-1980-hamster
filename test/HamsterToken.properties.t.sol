// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @notice Property tests at the arithmetic edges, with the known edge cases pinned beside them:
/// round trips, boundaries one unit either side of a balance or allowance, repeated calls, and the
/// exact set of events each operation emits.
/// forge-config: default.fuzz.runs = 1000
contract HamsterTokenPropertiesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    HamsterToken private token;
    address private alice;
    address private bob;
    address private carol;

    function setUp() public {
        token = new HamsterToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
    }

    /// @dev Any non-zero account that is not the deployer and not one of the named actors.
    function _account(uint256 seed) private view returns (address account) {
        account = address(uint160(bound(seed, 1, type(uint160).max)));
        if (account == address(this) || account == alice || account == bob || account == carol) {
            account = address(uint160(account) ^ uint160(0x1234_5678));
        }
        if (account == address(this) || account == alice || account == bob || account == carol) {
            account = address(uint160(account) + 1);
        }
    }

    // ---------------------------------------------------------------- round trips

    function testFuzz_TransferThenReturnRestoresEveryBalance(uint256 recipientSeed, uint256 amount) public {
        address recipient = _account(recipientSeed);
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        vm.prank(recipient);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_ThreeHopChainConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(carol, c);
        assertEq(token.balanceOf(address(this)), SUPPLY - a);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(carol), c);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol),
            SUPPLY
        );
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedRoundTripRestoresBalancesAndSpendsOnlyWhatMoved(uint256 amount, uint256 extra) public {
        amount = bound(amount, 0, SUPPLY);
        extra = bound(extra, 0, type(uint256).max - 1 - amount);
        token.approve(bob, amount + extra);
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, amount));
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(address(this), bob), extra);
        assertEq(token.allowance(alice, bob), 0);
    }

    // ---------------------------------------------------------------- boundaries

    function testFuzz_HolderCanSpendExactlyItsBalanceAndNotOneUnitMore(uint256 held) public {
        held = bound(held, 0, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + 1));
        token.transfer(bob, held + 1);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, held));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), held);
    }

    function testFuzz_AllowanceIsSpendableExactlyAndNotOneUnitMore(uint256 allowed) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, allowed + 1)
        );
        token.transferFrom(address(this), alice, allowed + 1);
        assertEq(token.allowance(address(this), bob), allowed);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, allowed));
        assertEq(token.allowance(address(this), bob), 0);
        assertEq(token.balanceOf(alice), allowed);
    }

    function testFuzz_AllowanceLargerThanBalanceIsCappedByTheBalance(uint256 held, uint256 allowed) public {
        held = bound(held, 0, SUPPLY - 1);
        allowed = bound(allowed, held + 1, type(uint256).max - 1);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + 1));
        token.transferFrom(alice, carol, held + 1);
        // The failed pull consumed nothing.
        assertEq(token.allowance(alice, bob), allowed);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(carol), 0);
    }

    function test_AllowanceOneBelowMaxIsFiniteAndDecreases() public {
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, 5 ether));
        assertEq(token.allowance(address(this), bob), type(uint256).max - 1 - 5 ether);
    }

    function test_InfiniteAllowanceStillCannotExceedBalance() public {
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transferFrom(address(this), alice, SUPPLY + 1);
        assertEq(token.allowance(address(this), bob), type(uint256).max);
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.allowance(address(this), bob), type(uint256).max);
    }

    function test_TransferFromBySelfStillNeedsASelfAllowance() public {
        // OpenZeppelin spends allowance[from][msg.sender] even when they are the same account.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
        token.approve(address(this), 1);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.allowance(address(this), address(this)), 0);
    }

    function testFuzz_ApprovalIsNotBoundedByBalance(uint256 allowed) public {
        allowed = bound(allowed, 0, type(uint256).max);
        vm.prank(alice);
        assertTrue(token.approve(bob, allowed));
        assertEq(token.allowance(alice, bob), allowed);
        assertEq(token.balanceOf(alice), 0);
        // Granting an allowance moves no tokens and gives the spender nothing to pull.
        if (allowed > 0) {
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
            token.transferFrom(alice, bob, 1);
        }
    }

    function testFuzz_UntouchedAccountsHoldNothingAndAllowNothing(uint256 seedA, uint256 seedB) public view {
        address a = _account(seedA);
        address b = _account(seedB);
        assertEq(token.balanceOf(a), 0);
        assertEq(token.allowance(a, b), 0);
        assertEq(token.allowance(b, a), 0);
        assertEq(token.allowance(address(this), a), 0);
    }

    function testFuzz_NoBalanceEverExceedsTheSupply(uint256 seed, uint256 amount) public {
        address recipient = _account(seed);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(recipient, amount);
        assertLe(token.balanceOf(recipient), token.totalSupply());
        assertLe(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.balanceOf(recipient) + token.balanceOf(address(this)), token.totalSupply());
    }

    // ---------------------------------------------------------------- repeated calls

    function testFuzz_RepeatedApproveIsIdempotent(uint256 allowed) public {
        allowed = bound(allowed, 0, type(uint256).max);
        token.approve(bob, allowed);
        token.approve(bob, allowed);
        assertEq(token.allowance(address(this), bob), allowed);
    }

    function test_HalfSupplyTwiceSucceedsAndAThirdTimeFails() public {
        uint256 half = SUPPLY / 2;
        assertTrue(token.transfer(alice, half));
        assertTrue(token.transfer(alice, half));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, half));
        token.transfer(alice, half);
        // A zero transfer from an emptied account still succeeds.
        assertTrue(token.transfer(alice, 0));
    }

    function test_SpendingTheSameAllowanceTwiceFailsTheSecondTime() public {
        token.approve(bob, 10 ether);
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, 10 ether));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 10 ether));
        token.transferFrom(address(this), alice, 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    // ---------------------------------------------------------------- events

    function testFuzz_TransferEmitsExactlyOneTransferAndNoApproval(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.recordLogs();
        token.transfer(alice, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), alice);
        assertEq(abi.decode(logs[0].data, (uint256)), amount);
    }

    function testFuzz_TransferFromEmitsOneTransferAndNoApprovalEvenWhenAllowanceShrinks(uint256 allowed, uint256 spent)
        public
    {
        allowed = bound(allowed, 0, SUPPLY);
        spent = bound(spent, 0, allowed);
        token.approve(bob, allowed);
        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(address(this), alice, spent);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom must emit exactly one event");
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), alice);
        assertEq(abi.decode(logs[0].data, (uint256)), spent);
        assertEq(token.allowance(address(this), bob), allowed - spent);
    }

    function testFuzz_ApproveEmitsExactlyOneApproval(uint256 allowed) public {
        allowed = bound(allowed, 0, type(uint256).max);
        vm.recordLogs();
        token.approve(bob, allowed);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], APPROVAL_TOPIC);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), allowed);
    }

    function test_ConstructorEmitsExactlyOneMintAndNothingElse() public {
        vm.recordLogs();
        HamsterToken fresh = new HamsterToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(this));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    // ---------------------------------------------------------------- failed calls leave no trace

    function testFuzz_FailedTransferEmitsNothingAndChangesNothing(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        token.transfer(alice, held);
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (bob, held + excess)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_ZeroAddressIsNeverAValidCounterparty(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        token.approve(bob, amount);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), bob), amount);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
