// SPDX-License-Identifier: MIT
// A mock for testing code that relies on VRFCoordinatorV2.
pragma solidity 0.8.24;

import "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract VRFCoordinatorV2PlusMock is VRFCoordinatorV2_5Mock {

    constructor(uint96 _baseFee, uint96 _gasPrice, int256 _weiPerUnitLink) VRFCoordinatorV2_5Mock(_baseFee, _gasPrice, _weiPerUnitLink) {
    }
}
