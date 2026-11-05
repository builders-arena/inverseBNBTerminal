// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Settable Chainlink AggregatorV3 mock for exercising the ChainlinkAdapter's edge paths
///         (decimals, negative/zero answer, zero updatedAt, incomplete round, staleness).
contract MockAggregator is AggregatorV3Interface {
    uint8 public decimals;
    string public description = "MOCK / USD";

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _answeredInRound;

    constructor(uint8 dec, int256 answer_) {
        decimals = dec;
        _roundId = 1;
        _answer = answer_;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }

    /// @notice Push a new complete round at the given answer/timestamp (roundId auto-increments).
    function set(int256 answer_, uint256 updatedAt_) external {
        _roundId += 1;
        _answer = answer_;
        _updatedAt = updatedAt_;
        _answeredInRound = _roundId;
    }

    /// @notice Set every field explicitly, including malformed combinations (e.g. answeredInRound < roundId).
    function setRaw(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        _roundId = roundId_;
        _answer = answer_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }
}
