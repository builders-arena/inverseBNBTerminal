// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Minimal IPriceOracle stand-in for the POOL slot in OracleRouterV4 routing tests.
contract MockPriceOracle is IPriceOracle {
    uint256 public price;
    uint256 public reserve;
    uint256 public floor;
    bool public supported = true;
    mapping(address => bool) public halted;
    uint256 public snapshotCalls;
    address public lastSnapshot;

    constructor(uint256 price_, uint256 reserve_, uint256 floor_) {
        price = price_;
        reserve = reserve_;
        floor = floor_;
    }

    function snapshot(address token) external {
        snapshotCalls++;
        lastSnapshot = token;
    }

    function getPrice(address) external view returns (uint256) {
        return price;
    }

    function pairReserveWbnb(address) external view returns (uint256) {
        return reserve;
    }

    function LIQ_FLOOR() external view returns (uint256) {
        return floor;
    }

    function status(address token) external view returns (Status memory s) {
        s.supported = supported;
        s.route = Route.V2;
        s.halted = halted[token];
        s.reserveBnb = reserve;
        s.spot = price;
        s.twap = price;
    }

    function isSupported(address) external view returns (bool) {
        return supported;
    }

    function setHalted(address token, bool value) external {
        halted[token] = value;
    }

    function setRouteOverride(address, Route) external {}
}
