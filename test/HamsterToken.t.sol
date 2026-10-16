// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @dev Test-only factory, exercising the launch's CREATE2 and exact-transfer requirements.
contract FactoryHarness {
    address private immutable controller = msg.sender;

    function deploy(bytes32 salt) external returns (HamsterToken) {
        require(msg.sender == controller, "controller only");
        return new HamsterToken{salt: salt}();
    }

    function move(HamsterToken token, address recipient, uint256 amount) external {
        require(msg.sender == controller, "controller only");
        require(token.transfer(recipient, amount), "transfer failed");
    }
}

/// @dev Token transfers must not invoke recipient callbacks, even for a rejecting recipient.
contract RejectingRecipient {
    fallback() external {
        revert("no callbacks");
    }
}

contract HamsterTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address private constant TREASURY = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;

    HamsterToken private token;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new HamsterToken();
    }

    function test_MetadataAndEntireSupplyBelongToDeployer() public view {
        assertEq(token.name(), "HAMSTER");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_ConstructorEmitsMintEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new HamsterToken();
    }

    function test_FactoryReceivesWholeSupplyThenDistributesExactLaunchShares() public {
        FactoryHarness factory = new FactoryHarness();
        HamsterToken launched = factory.deploy(keccak256("HAMSTER launch"));
        address distributor = makeAddr("Swarm distributor test double");
        address pool = makeAddr("pool manager test double");
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(TREASURY), 0);

        uint256 swarmShare = 100_000_000 * 10 ** 18;
        uint256 poolShare = 100_000_000 * 10 ** 18;
        uint256 vaultShare = 800_000_000 * 10 ** 18;
        factory.move(launched, distributor, swarmShare);
        factory.move(launched, pool, poolShare);
        factory.move(launched, TREASURY, vaultShare);

        assertEq(launched.balanceOf(distributor), swarmShare);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.balanceOf(TREASURY), vaultShare);
        assertEq(launched.balanceOf(address(factory)), 0);

        vm.prank(distributor);
        assertTrue(launched.transfer(alice, swarmShare));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(alice), swarmShare);

        // Exercise both pool transfer directions; actual AMM swaps belong to the launch harness.
        vm.prank(pool);
        assertTrue(launched.transfer(bob, 15 ether));
        assertEq(launched.balanceOf(bob), 15 ether);
        vm.prank(bob);
        assertTrue(launched.transfer(pool, 15 ether));
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TransferReturnsTrueAndEmitsExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 123 ether);
        assertTrue(token.transfer(alice, 123 ether));
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFullBalance() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_SelfTransferLeavesBalanceUnchanged() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferRejectsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferRejectsZeroRecipientEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_TransferRejectsInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferToContractDoesNotCallRecipient() public {
        RejectingRecipient recipient = new RejectingRecipient();
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
    }

    function test_ApprovalEmitsEventAndCanBeReplacedAndRevoked() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 50 ether);
        assertTrue(token.approve(spender, 50 ether));
        assertEq(token.allowance(address(this), spender), 50 ether);
        assertTrue(token.approve(spender, 20 ether));
        assertEq(token.allowance(address(this), spender), 20 ether);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(address(this), spender), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_ApproveRejectsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_TransferFromConsumesAllowanceAndEmitsTransfer() public {
        token.approve(spender, 30 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 20 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 20 ether));
        assertEq(token.balanceOf(alice), 20 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 20 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 10 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 30 ether);
    }

    function test_InfiniteAllowanceIsNotDecreased() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 20 ether));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 20 ether);
    }

    function test_TransferFromRejectsOverspendingAllowanceAtomically() public {
        token.approve(spender, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10 ether, 11 ether)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, 11 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_TransferFromRejectsInsufficientBalanceWithoutConsumingAllowance() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromRejectsZeroRecipientWithoutConsumingAllowance() public {
        token.approve(spender, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferFromRejectsZeroSender() public {
        // OpenZeppelin spends the allowance first, so a zero owner fails approval validation.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function test_ZeroTransferFromNeedsNoAllowance() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_DeployerCannotSpendHolderFundsWithoutApproval() public {
        token.transfer(alice, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, address(this), 1);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_NoMintBurnAdminOrUpgradeEntryPoints() public {
        token.transfer(alice, 100 ether);
        bytes[] memory calls = new bytes[](24);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("issue(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("setOwner(address)", bob);
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", bob);
        calls[7] = abi.encodeWithSignature("initialize(address)", bob);
        calls[8] = abi.encodeWithSignature("unpause()");
        calls[9] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[10] = abi.encodeWithSignature("pause()");
        calls[11] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[12] = abi.encodeWithSignature("blocklist(address)", alice);
        calls[13] = abi.encodeWithSignature("freeze(address)", alice);
        calls[14] = abi.encodeWithSignature("freezeAccount(address)", alice);
        calls[15] = abi.encodeWithSignature("setBlacklist(address,bool)", alice, true);
        calls[16] = abi.encodeWithSignature("setBlocked(address,bool)", alice, true);
        calls[17] = abi.encodeWithSignature("lock(address)", alice);
        calls[18] = abi.encodeWithSignature("disableTransfers()");
        calls[19] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[20] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[21] = abi.encodeWithSignature("seize(address)", alice);
        calls[22] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[23] = abi.encodeWithSignature("owner()");

        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSuccess,) = address(token).call(calls[i]);
            assertFalse(deployerSuccess);
            vm.prank(bob);
            (bool strangerSuccess,) = address(token).call(calls[i]);
            assertFalse(strangerSuccess);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(alice), 100 ether);
            assertEq(token.balanceOf(bob), 0);
        }
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100 ether));
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_RejectsEtherAndUnknownCalldata() public {
        vm.deal(address(this), 1 ether);
        (bool acceptedEther,) = address(token).call{value: 1 ether}("");
        assertFalse(acceptedEther);
        (bool acceptedSelector,) = address(token).call(hex"ffffffff");
        assertFalse(acceptedSelector);
        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RuntimeHasNoForbiddenOpcodesAndFitsSizeLimit() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }

    function testFuzz_TransferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_SelfTransferConservesBalance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferFromHonorsFiniteAllowance(uint256 approved, uint256 spent) public {
        approved = bound(approved, 0, SUPPLY);
        spent = bound(spent, 0, approved);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, spent));
        assertEq(token.allowance(address(this), spender), approved - spent);
        assertEq(token.balanceOf(alice), spent);
        assertEq(token.balanceOf(address(this)), SUPPLY - spent);
    }

    function testFuzz_TransferFromToSelfConsumesAllowanceWithoutMovingBalance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), amount));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_OverdrawRevertsWithoutChangingSupply(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_UnapprovedSpendingAlwaysReverts(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }
}
