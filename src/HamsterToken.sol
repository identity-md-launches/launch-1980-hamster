// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title HAMSTER
/// @notice Fixed-supply ERC-20 for the HAMSTER launch.
/// @dev The launch factory receives the entire supply as the immediate deployer.
///      It handles the 10% pool, 80% treasury/vault, and 10% Swarm allocations.
///      There are no administrative powers, transfer fees, or post-deployment mint/burn functions.
contract HamsterToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("HAMSTER", "HAMSTER") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
