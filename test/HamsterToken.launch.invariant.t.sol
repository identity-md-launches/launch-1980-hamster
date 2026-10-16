// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @dev Drives the token after the launch split: the pool double, the treasury, the distributor
/// and a crowd of traders move tokens in random order, while every failure path (overdraw,
/// unapproved pull, zero recipient, privileged calls, ether) is attempted alongside and must leave
/// no trace. Ghost totals of what flowed in and out of each account are kept independently.
contract LaunchHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 10 ** 18;

    HamsterToken public immutable token;
    address public immutable factory;
    address public immutable distributor;
    address public immutable pool;
    address public immutable treasury;
    address public immutable stranger;
    address[] public actors;

    mapping(address => uint256) public initialBalance;
    mapping(address => uint256) public flowedIn;
    mapping(address => uint256) public flowedOut;
    mapping(address => mapping(address => bool)) public everApproved;
    uint256 public claimed;
    uint256 public failedAttempts;
    uint256 public successfulMoves;

    constructor(
        HamsterToken token_,
        address factory_,
        address distributor_,
        address pool_,
        address treasury_,
        address stranger_,
        address[] memory traders
    ) {
        token = token_;
        factory = factory_;
        distributor = distributor_;
        pool = pool_;
        treasury = treasury_;
        stranger = stranger_;
        actors.push(distributor_);
        actors.push(pool_);
        actors.push(treasury_);
        actors.push(factory_);
        for (uint256 i; i < traders.length; ++i) {
            actors.push(traders[i]);
        }
        for (uint256 i; i < actors.length; ++i) {
            initialBalance[actors[i]] = token_.balanceOf(actors[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _expected(address who) private view returns (uint256) {
        return initialBalance[who] + flowedIn[who] - flowedOut[who];
    }

    // ------------------------------------------------------------ successful paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 toBefore = token.balanceOf(to);
        uint256 fromBefore = token.balanceOf(from);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self transfer changed a balance");
        } else {
            assertEq(token.balanceOf(to), toBefore + amount, "recipient credited the wrong amount");
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited the wrong amount");
        }
        flowedOut[from] += amount;
        flowedIn[to] += amount;
        successfulMoves += 1;
    }

    function claim(uint256 toSeed, uint256 amount) external {
        address claimant = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(distributor));
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, amount), "claim returned false");
        flowedOut[distributor] += amount;
        flowedIn[claimant] += amount;
        if (claimant != distributor) claimed += amount;
        successfulMoves += 1;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = infinite ? type(uint256).max : bound(amount, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "allowance not recorded");
        everApproved[owner][spender] = true;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 held = token.balanceOf(from);
        amount = bound(amount, 0, held < allowed ? held : allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount), "transferFrom returned false");
        assertEq(
            token.allowance(from, spender),
            allowed == type(uint256).max ? allowed : allowed - amount,
            "allowance spent incorrectly"
        );
        flowedOut[from] += amount;
        flowedIn[to] += amount;
        successfulMoves += 1;
    }

    // ------------------------------------------------------------ failure paths, every one expected

    function overdraw(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, held + excess)
        );
        token.transfer(to, held + excess);
        assertEq(token.balanceOf(from), held, "a failed overdraw changed the sender");
        failedAttempts += 1;
    }

    function pullBeyondAllowance(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        if (allowed == type(uint256).max) {
            // Unlimited allowance: the only ceiling left is the balance.
            uint256 held = token.balanceOf(from);
            excess = bound(excess, 1, type(uint256).max - held);
            vm.prank(spender);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, held + excess)
            );
            token.transferFrom(from, to, held + excess);
            assertEq(token.allowance(from, spender), type(uint256).max, "unlimited allowance was consumed");
        } else {
            excess = bound(excess, 1, type(uint256).max - allowed);
            vm.prank(spender);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + excess
                )
            );
            token.transferFrom(from, to, allowed + excess);
            assertEq(token.allowance(from, spender), allowed, "a failed pull consumed allowance");
        }
        failedAttempts += 1;
    }

    function sendToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        failedAttempts += 1;
    }

    function strangerPulls(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 1, SUPPLY);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(from, stranger, amount);
        failedAttempts += 1;
    }

    function privilegedCall(uint256 callerSeed, uint256 targetSeed, uint256 which) external {
        address caller = callerSeed % 2 == 0 ? factory : _actor(callerSeed);
        address target = _actor(targetSeed);
        string[14] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "seize(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], target, SUPPLY);
        uint256 targetBefore = token.balanceOf(target);
        uint256 callerBefore = token.balanceOf(caller);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a privileged selector was accepted");
        assertEq(token.balanceOf(target), targetBefore, "a privileged call moved a target balance");
        assertEq(token.balanceOf(caller), callerBefore, "a privileged call moved the caller balance");
        failedAttempts += 1;
    }

    function sendEther(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 1, 100 ether);
        vm.deal(from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
        failedAttempts += 1;
    }

    // ------------------------------------------------------------ model checks

    function assertBalancesMatchFlows() external view {
        for (uint256 i; i < actors.length; ++i) {
            address who = actors[i];
            assertEq(token.balanceOf(who), _expected(who), "balance differs from recorded flows");
            assertLe(token.balanceOf(who), SUPPLY, "a balance exceeds the supply");
        }
    }

    function assertNeverApprovedPairsHaveNoAllowance() external view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                if (!everApproved[actors[i]][actors[j]]) {
                    assertEq(token.allowance(actors[i], actors[j]), 0, "an allowance appeared without approval");
                }
            }
            assertEq(token.allowance(actors[i], stranger), 0, "the stranger gained an allowance");
        }
    }

    function sumOfActorBalances() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += token.balanceOf(actors[i]);
        }
    }
}

/// @notice Invariants over the launched token: the supply never changes, what the tracked accounts
/// hold is exactly the supply, each account holds its initial share plus what flowed in minus what
/// flowed out, the distributor holds the swarm share less what was claimed, nobody who was never
/// approved can spend, the stranger never gains anything, and the code never changes.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterTokenLaunchInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address private constant TREASURY = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;

    HamsterToken private token;
    LaunchHandler private handler;
    address private factory;
    address private distributor;
    address private pool;
    address private stranger;
    uint256 private swarmShare;
    bytes32 private codeHash;

    function setUp() public {
        factory = makeAddr("launch factory test double");
        distributor = makeAddr("merkle distributor test double");
        pool = makeAddr("pool manager test double");
        stranger = makeAddr("stranger who holds nothing");

        // The factory deploys, receives the supply and performs the 10/80/10 split.
        vm.prank(factory);
        token = new HamsterToken();
        swarmShare = (SUPPLY * 1_000) / 10_000;
        uint256 poolShare = (SUPPLY * 1_000) / 10_000;
        vm.startPrank(factory);
        token.transfer(distributor, swarmShare);
        token.transfer(pool, poolShare);
        token.transfer(TREASURY, SUPPLY - swarmShare - poolShare);
        vm.stopPrank();
        assertEq(token.balanceOf(factory), 0);
        codeHash = keccak256(address(token).code);

        address[] memory traders = new address[](5);
        for (uint256 i; i < traders.length; ++i) {
            traders[i] = makeAddr(string.concat("trader ", vm.toString(i)));
        }
        handler = new LaunchHandler(token, factory, distributor, pool, TREASURY, stranger, traders);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = LaunchHandler.transfer.selector;
        selectors[1] = LaunchHandler.claim.selector;
        selectors[2] = LaunchHandler.approve.selector;
        selectors[3] = LaunchHandler.transferFrom.selector;
        selectors[4] = LaunchHandler.overdraw.selector;
        selectors[5] = LaunchHandler.pullBeyondAllowance.selector;
        selectors[6] = LaunchHandler.sendToZero.selector;
        selectors[7] = LaunchHandler.strangerPulls.selector;
        selectors[8] = LaunchHandler.privilegedCall.selector;
        selectors[9] = LaunchHandler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SupplyIsFixedAndFullyHeldByTrackedAccounts() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(handler.sumOfActorBalances(), SUPPLY, "tracked balances do not sum to the supply");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_EveryBalanceEqualsInitialPlusInflowsMinusOutflows() public view {
        handler.assertBalancesMatchFlows();
    }

    function invariant_DistributorHoldsSwarmShareLessClaims() public view {
        assertEq(
            token.balanceOf(distributor),
            swarmShare + handler.flowedIn(distributor) - handler.flowedOut(distributor),
            "distributor ledger drifted"
        );
        assertLe(
            handler.claimed(), swarmShare + handler.flowedIn(distributor), "claims exceed what the distributor held"
        );
    }

    function invariant_NobodySpendsWithoutApprovalAndTheStrangerGainsNothing() public view {
        handler.assertNeverApprovedPairsHaveNoAllowance();
        assertEq(token.balanceOf(stranger), 0, "the stranger acquired tokens");
        assertEq(token.balanceOf(factory), handler.flowedIn(factory) - handler.flowedOut(factory));
    }

    function invariant_TokenHoldsNoEtherAndItsCodeNeverChanges() public view {
        assertEq(address(token).balance, 0, "the token holds ether");
        assertEq(keccak256(address(token).code), codeHash, "the token's runtime changed");
    }

    function invariant_FailurePathsWereExercised() public view {
        // Guards against a vacuous run: the fuzzer has to reach the failure handlers too.
        if (handler.successfulMoves() > 20) {
            assertGt(handler.failedAttempts(), 0, "no failure path was attempted");
        }
    }
}
