// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPancakeV2Factory} from "../../src/interfaces/IPancakeV2Factory.sol";

contract MockV2Factory is IPancakeV2Factory {
    mapping(address => mapping(address => address)) public pairs;

    function setPair(address a, address b, address pair) external {
        pairs[a][b] = pair;
        pairs[b][a] = pair;
    }

    function getPair(address a, address b) external view returns (address) {
        return pairs[a][b];
    }
}
