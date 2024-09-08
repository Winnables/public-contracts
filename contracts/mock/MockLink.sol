// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@chainlink/contracts/src/v0.8/mocks/MockLinkToken.sol";

contract MockLink is MockLinkToken {
  function mint(address to, uint256 amount) external {
    balances[to] += amount;
  }
}
