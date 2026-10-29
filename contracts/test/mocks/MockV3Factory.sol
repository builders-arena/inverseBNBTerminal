// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPancakeV3Factory} from "../../src/interfaces/IPancakeV3Factory.sol";

contract MockV3Factory is IPancakeV3Factory {
    mapping(bytes32 => address) public pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[_key(a, b, fee)] = pool;
        pools[_key(b, a, fee)] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[_key(a, b, fee)];
    }

    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, fee));
    }
}
