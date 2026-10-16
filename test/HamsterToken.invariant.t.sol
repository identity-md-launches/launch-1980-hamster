// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @dev Random sequences of transfers, approvals, revocations and delegated transfers.
///      Independent accounting checks every balance and allowance after every operation.
contract HamsterHandler is Test {
    HamsterToken public immutable token;
    address[4] private actors;
    mapping(address => uint256) private expectedBalance;
    mapping(address => mapping(address => uint256)) private expectedAllowance;

    constructor(HamsterToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = 1_000_000_000 * 10 ** 18;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        assertAccounting();
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = infinite ? type(uint256).max : bound(amount, 0, 1_000_000_000 * 10 ** 18);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        assertAccounting();
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        assertAccounting();
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[from][spender];
        uint256 maximum = expectedBalance[from] < allowed ? expectedBalance[from] : allowed;
        amount = bound(amount, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) {
            expectedAllowance[from][spender] -= amount;
        }
        assertAccounting();
    }

    function assertAccounting() public view {
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            assertEq(token.balanceOf(actor), expectedBalance[actor], "balance differs from model");
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actor, actors[j]),
                    expectedAllowance[actor][actors[j]],
                    "allowance differs from model"
                );
            }
        }
    }
}

contract HamsterTokenInvariantTest is StdInvariant, Test {
    HamsterToken private token;
    HamsterHandler private handler;
    address[4] private actors;

    function setUp() public {
        token = new HamsterToken();
        actors = [makeAddr("holder A"), makeAddr("holder B"), makeAddr("holder C"), makeAddr("holder D")];
        token.transfer(actors[0], token.totalSupply());
        handler = new HamsterHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = HamsterHandler.transfer.selector;
        selectors[1] = HamsterHandler.approve.selector;
        selectors[2] = HamsterHandler.revoke.selector;
        selectors[3] = HamsterHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SupplyAndAllBalancesAreConserved() public view {
        uint256 total;
        for (uint256 i; i < actors.length; ++i) {
            total += token.balanceOf(actors[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(total, token.totalSupply());
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_BalancesAndAllowancesMatchIndependentModel() public view {
        handler.assertAccounting();
    }
}
