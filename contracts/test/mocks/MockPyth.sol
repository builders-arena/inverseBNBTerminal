// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPyth} from "../../src/interfaces/IPyth.sol";

/// @notice Minimal Pyth mock: settable per-feed price with a real staleness check.
contract MockPyth is IPyth {
    mapping(bytes32 => Price) internal _prices;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _prices[id] = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory) {
        Price memory p = _prices[id];
        require(p.publishTime != 0, "no feed");
        if (block.timestamp > p.publishTime + age) revert("StalePrice");
        return p;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory) {
        return _prices[id];
    }
}
