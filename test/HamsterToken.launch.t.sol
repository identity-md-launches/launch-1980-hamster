// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterToken} from "../src/HamsterToken.sol";

/// @notice The ERC-20 subset the launch floor reads, declared here so these tests do not lean on
/// the token's own ABI for what the factory, distributor and pool manager call.
interface ILaunchToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @dev Shaped like the protected harness's probe: etched at the factory's address, it deploys the
/// attested creation code through raw CREATE2 and verifies, inside the same call, that the
/// constructor minted the manifest supply to the factory and nothing else moved it.
contract LaunchProbe {
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "not the harness");
        _;
    }

    function deploy(bytes memory code, bytes32 salt) external onlyController returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
    }

    function deployAll(bytes[] memory codes, bytes32[] memory salts, uint256 expectedSupply)
        external
        onlyController
        returns (address[] memory deployed)
    {
        require(codes.length > 0 && codes.length == salts.length && codes.length <= 9, "invalid project list");
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length > 0, "constructor failed");
            deployed[i] = created;
            ILaunchToken token = ILaunchToken(deployed[0]);
            require(expectedSupply > 0 && token.totalSupply() == expectedSupply, "manifest supply mismatch");
            require(token.balanceOf(address(this)) == expectedSupply, "a constructor moved the launch supply");
        }
    }

    function move(ILaunchToken token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Launch-shaped checks: the token deployed the way the factory deploys it, at the address
/// the salt predicts, with the whole supply where the factory expects it, and the 10/80/10 split the
/// requester asked for moving exactly.
contract HamsterTokenLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant BPS = 10_000;
    uint256 private constant SWARM_BPS = 1_000;
    uint256 private constant POOL_BPS = 1_000;
    address private constant TREASURY = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;
    uint64 private constant LAUNCH_NUMBER = 7_331;

    address private factory;
    LaunchProbe private probe;
    ILaunchToken private token;
    address private distributor;
    address private poolManager;

    function setUp() public {
        factory = makeAddr("launch factory test double");
        distributor = makeAddr("merkle distributor test double");
        poolManager = makeAddr("pool manager test double");
        LaunchProbe implementation = new LaunchProbe();
        vm.etch(factory, address(implementation).code);
        probe = LaunchProbe(factory);

        bytes[] memory codes = new bytes[](1);
        bytes32[] memory salts = new bytes32[](1);
        codes[0] = type(HamsterToken).creationCode;
        salts[0] = bytes32(uint256(LAUNCH_NUMBER));
        address[] memory deployed = probe.deployAll(codes, salts, SUPPLY);
        token = ILaunchToken(deployed[0]);
    }

    function _predict(address deployer, bytes32 salt, bytes memory code) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(code))))));
    }

    function test_DeploysAtTheSaltPredictedAddressWithNoConstructorArguments() public view {
        bytes memory code = type(HamsterToken).creationCode;
        assertEq(address(token), _predict(factory, bytes32(uint256(LAUNCH_NUMBER)), code));
        // The manifest's constructorArgs is empty: the attested creation code deploys as is.
        assertEq(address(token).code.length, type(HamsterToken).runtimeCode.length);
        assertEq(keccak256(address(token).code), keccak256(type(HamsterToken).runtimeCode));
        // The Solidity identifier is recorded as 32 bytes by the factory.
        assertLe(bytes("HamsterToken").length, 32);
    }

    function test_FactoryHoldsTheManifestSupplyAfterDeployment() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(factory), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(uint256(token.decimals()), 18);
    }

    function test_ManifestSupplyMismatchIsCaughtInsideTheDeployingCall() public {
        bytes[] memory codes = new bytes[](1);
        bytes32[] memory salts = new bytes32[](1);
        codes[0] = type(HamsterToken).creationCode;
        salts[0] = bytes32(uint256(LAUNCH_NUMBER) + 1);
        vm.expectRevert(bytes("manifest supply mismatch"));
        probe.deployAll(codes, salts, SUPPLY - 1);
        vm.expectRevert(bytes("manifest supply mismatch"));
        probe.deployAll(codes, salts, SUPPLY + 1);
        vm.expectRevert(bytes("manifest supply mismatch"));
        probe.deployAll(codes, salts, 0);
    }

    function test_SameSaltCannotRedeployTheToken() public {
        // CREATE2 refuses a second deployment at an occupied address: the launch number is final.
        // A colliding CREATE2 burns the gas it is given, so the call is capped.
        address again = probe.deploy{gas: 2_000_000}(type(HamsterToken).creationCode, bytes32(uint256(LAUNCH_NUMBER)));
        assertEq(again, address(0));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(factory), SUPPLY);
    }

    function test_SecondLaunchNumberMintsAnIndependentSupplyToTheSameFactory() public {
        bytes32 salt = bytes32(uint256(LAUNCH_NUMBER) + 1);
        address second = probe.deploy(type(HamsterToken).creationCode, salt);
        assertEq(second, _predict(factory, salt, type(HamsterToken).creationCode));
        assertTrue(second != address(token));
        assertEq(ILaunchToken(second).totalSupply(), SUPPLY);
        assertEq(ILaunchToken(second).balanceOf(factory), SUPPLY);
        // Each token's ledger is its own: moving one does not touch the other.
        probe.move(token, TREASURY, 1 ether);
        assertEq(ILaunchToken(second).balanceOf(TREASURY), 0);
        assertEq(ILaunchToken(second).balanceOf(factory), SUPPLY);
    }

    function test_OnlyTheProbeControllerDrivesTheFactory() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("not the harness"));
        probe.move(token, TREASURY, 1);
        assertEq(token.balanceOf(factory), SUPPLY);
    }

    function test_LaunchFlowsMoveExactlyTenEightyTenAndEmptyTheFactory() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / BPS;
        uint256 pool = (SUPPLY * POOL_BPS) / BPS;
        uint256 remainder = SUPPLY - swarm - pool;
        assertEq(swarm, 100_000_000 * 10 ** 18);
        assertEq(pool, 100_000_000 * 10 ** 18);
        assertEq(remainder, 800_000_000 * 10 ** 18);

        assertTrue(probe.move(token, distributor, swarm), "swarm transfer returned false");
        assertEq(token.balanceOf(distributor), swarm, "swarm share arrived short");
        assertTrue(probe.move(token, poolManager, pool), "pool transfer returned false");
        assertEq(token.balanceOf(poolManager), pool, "pool seed arrived short");
        assertTrue(probe.move(token, TREASURY, remainder), "remainder transfer returned false");
        assertEq(token.balanceOf(TREASURY), remainder, "remainder arrived short");

        assertEq(token.balanceOf(factory), 0, "factory kept something back");
        assertEq(token.totalSupply(), SUPPLY, "launch flows changed the supply");
        assertEq(token.balanceOf(distributor) + token.balanceOf(poolManager) + token.balanceOf(TREASURY), SUPPLY);
    }

    function test_FactoryCannotForwardMoreThanTheSupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, factory, SUPPLY, SUPPLY + 1)
        );
        probe.move(token, TREASURY, SUPPLY + 1);
        uint256 swarm = (SUPPLY * SWARM_BPS) / BPS;
        probe.move(token, distributor, swarm);
        // After the swarm share has left, the old whole-supply remainder is no longer available.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, factory, SUPPLY - swarm, SUPPLY)
        );
        probe.move(token, TREASURY, SUPPLY);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.balanceOf(factory), SUPPLY - swarm);
    }

    function test_SwarmShareIsClaimableWholeAcrossUnevenClaims() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / BPS;
        probe.move(token, distributor, swarm);
        // Two percent split among contributors, eight percent among seats, with uneven, indivisible pieces.
        uint256[] memory claims = new uint256[](7);
        claims[0] = swarm / 50 / 3; // three contributors sharing two percent, rounded down
        claims[1] = swarm / 50 / 3;
        claims[2] = swarm / 50 - 2 * claims[0]; // the third takes the rounding remainder
        claims[3] = (swarm - swarm / 50) / 4 + 1;
        claims[4] = (swarm - swarm / 50) / 4 - 1;
        claims[5] = 1;
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += claims[i];
        }
        claims[6] = swarm - sum;
        uint256 claimedTotal;
        for (uint256 i; i < claims.length; ++i) {
            address claimant = makeAddr(string.concat("claimant ", vm.toString(i)));
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, claims[i]), "a claim returned false");
            assertEq(token.balanceOf(claimant), claims[i], "a claim arrived short");
            claimedTotal += claims[i];
            assertEq(token.balanceOf(distributor), swarm - claimedTotal, "distributor ledger drifted");
        }
        assertEq(claimedTotal, swarm);
        assertEq(token.balanceOf(distributor), 0, "the distributor kept something back");
        // One more claim of a single unit is refused: nothing is left to claim.
        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, 0, 1));
        token.transfer(makeAddr("late claimant"), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_PoolManagerPullsBySettledAllowanceAndPaysOutExactly() public {
        uint256 pool = (SUPPLY * POOL_BPS) / BPS;
        probe.move(token, poolManager, pool);
        address trader = makeAddr("trader");
        // Buy: the pool pays the trader out exactly.
        vm.prank(poolManager);
        assertTrue(token.transfer(trader, 1234 ether));
        assertEq(token.balanceOf(trader), 1234 ether);
        // Sell: the manager settles by pulling an approved amount, and gets exactly that.
        vm.prank(trader);
        token.approve(poolManager, 1234 ether);
        vm.prank(poolManager);
        assertTrue(token.transferFrom(trader, poolManager, 1234 ether));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.allowance(trader, poolManager), 0);
        // Pulling more than was settled is refused: the manager has no special standing.
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, poolManager, 0, 1));
        token.transferFrom(trader, poolManager, 1);
    }

    function test_NoCommonAdminCallIncreasesSupplyFromStrangerOrFactory() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
            vm.prank(factory);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(factory), SUPPLY, signatures[i]);
        }
    }

    function test_NoPrivilegedHandMovesOrFreezesAHolderFromTheFactory() public {
        address holder = makeAddr("holder");
        address other = makeAddr("other");
        probe.move(token, holder, SUPPLY / 1_000);
        uint256 held = token.balanceOf(holder);
        assertGt(held, 0);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], holder, true);
            vm.prank(factory);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.balanceOf(holder), held, signatures[i]);
        }
        vm.prank(factory);
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(ILaunchToken.transferFrom.selector, holder, factory, 1));
        assertFalse(moved, "the factory pulled from a holder without approval");
        assertEq(token.balanceOf(holder), held, "a privileged call moved the holder's balance");
        vm.prank(holder);
        assertTrue(token.transfer(other, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(other), held / 2);
        assertEq(token.balanceOf(holder), held - held / 2);
    }

    function test_RuntimeMatchesCompilerOutputAndHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}
