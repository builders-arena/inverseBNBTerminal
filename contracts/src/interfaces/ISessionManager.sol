// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ISessionManager {
    struct Session {
        address trader;
        uint256 budget; // total BNB committed
        uint256 spent; // BNB consumed by opened positions
        uint256 maxPerTrade; // cap per intent
        uint256 expiry; // unix timestamp
        uint256 nonce; // next expected intent nonce
        bool active;
    }

    struct TradeIntent {
        uint256 sessionId;
        address token;
        bool isLong;
        uint8 leverage;
        uint256 amount;
        uint256 tpPrice;
        uint256 slPrice;
        uint256 nonce;
        uint256 deadline;
    }

    struct CloseIntent {
        uint256 sessionId;
        uint256 positionId;
        uint256 nonce;
        uint256 deadline;
    }

    function createSession(uint256 maxPerTrade, uint256 duration) external payable returns (uint256 id);
    function revokeSession(uint256 id) external;
    function withdrawUnspent(uint256 id) external;

    function executeIntent(TradeIntent calldata intent, bytes calldata sig) external returns (uint256 positionId);
    function executeClose(CloseIntent calldata intent, bytes calldata sig) external;

    function getSession(uint256 id) external view returns (Session memory);
}
