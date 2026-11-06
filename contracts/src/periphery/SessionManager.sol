// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISessionManager} from "../interfaces/ISessionManager.sol";
import {IInverseEngine} from "../interfaces/IStkmemesEngine.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title  SessionManager
/// @notice One-click trading: a trader funds a time-boxed session, then signs EIP-712 trade/close
///         intents off-chain. Anyone (a relayer) may submit a signed intent; relayers are only gas
///         payers and cannot alter terms. Holds user collateral, so it is treated with the same custody
///         rigor as the Vault: no admin withdrawal path, explicit per-session accounting, ReentrancyGuard.
contract SessionManager is ISessionManager, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset; // collateral token (settlement asset, e.g. USDC)

    bytes32 public constant TRADE_INTENT_TYPEHASH = keccak256(
        "TradeIntent(uint256 sessionId,address token,bool isLong,uint8 leverage,uint256 amount,uint256 tpPrice,uint256 slPrice,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant CLOSE_INTENT_TYPEHASH =
        keccak256("CloseIntent(uint256 sessionId,uint256 positionId,uint256 nonce,uint256 deadline)");

    uint256 public constant MAX_DURATION = 24 hours;

    IInverseEngine public immutable engine;

    uint256 public nextSessionId = 1;
    mapping(uint256 => Session) private _sessions;

    event SessionCreated(uint256 indexed id, address indexed trader, uint256 budget, uint256 maxPerTrade, uint256 expiry);
    event IntentExecuted(uint256 indexed id, uint256 indexed positionId, uint256 amount, uint256 nonce);
    event CloseExecuted(uint256 indexed id, uint256 indexed positionId, uint256 nonce);
    event SessionRevoked(uint256 indexed id);
    event UnspentWithdrawn(uint256 indexed id, uint256 amount);

    constructor(address asset_, address engine_) EIP712("InverseSessionManager", "1") {
        if (asset_ == address(0) || engine_ == address(0)) revert Errors.ZeroAddress();
        asset = IERC20(asset_);
        engine = IInverseEngine(engine_);
        // Pre-approve the engine to pull per-trade collateral when executing intents.
        asset.forceApprove(engine_, type(uint256).max);
    }

    // =========================================================================
    //                              SESSION LIFECYCLE
    // =========================================================================

    /// @inheritdoc ISessionManager
    function createSession(uint256 budget, uint256 maxPerTrade, uint256 duration)
        external
        returns (uint256 id)
    {
        if (budget == 0 || maxPerTrade == 0) revert Errors.ZeroAmount();
        if (maxPerTrade > budget) revert Errors.PerTradeExceeded(maxPerTrade, budget);
        if (duration == 0 || duration > MAX_DURATION) revert Errors.OutOfBounds(duration, 1, MAX_DURATION);

        asset.safeTransferFrom(msg.sender, address(this), budget);

        id = nextSessionId++;
        _sessions[id] = Session({
            trader: msg.sender,
            budget: budget,
            spent: 0,
            maxPerTrade: maxPerTrade,
            expiry: block.timestamp + duration,
            nonce: 0,
            active: true
        });
        emit SessionCreated(id, msg.sender, budget, maxPerTrade, block.timestamp + duration);
    }

    /// @inheritdoc ISessionManager
    function revokeSession(uint256 id) external {
        Session storage s = _sessions[id];
        if (s.trader != msg.sender) revert Errors.NotSessionOwner();
        s.active = false;
        emit SessionRevoked(id);
    }

    /// @inheritdoc ISessionManager
    function withdrawUnspent(uint256 id) external nonReentrant {
        Session storage s = _sessions[id];
        if (s.trader != msg.sender) revert Errors.NotSessionOwner();
        uint256 remaining = s.budget - s.spent;
        if (remaining == 0) revert Errors.ZeroAmount();
        s.spent = s.budget; // mark fully withdrawn
        s.active = false;
        emit UnspentWithdrawn(id, remaining);
        asset.safeTransfer(msg.sender, remaining);
    }

    // =========================================================================
    //                                 INTENTS
    // =========================================================================

    /// @inheritdoc ISessionManager
    function executeIntent(TradeIntent calldata intent, bytes calldata sig)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        Session storage s = _sessions[intent.sessionId];
        _checkSession(s, intent.nonce, intent.deadline);
        if (intent.amount > s.maxPerTrade) revert Errors.PerTradeExceeded(intent.amount, s.maxPerTrade);
        if (s.spent + intent.amount > s.budget) {
            revert Errors.SessionBudgetExceeded(s.spent, intent.amount, s.budget);
        }

        bytes32 structHash = keccak256(
            abi.encode(
                TRADE_INTENT_TYPEHASH,
                intent.sessionId,
                intent.token,
                intent.isLong,
                intent.leverage,
                intent.amount,
                intent.tpPrice,
                intent.slPrice,
                intent.nonce,
                intent.deadline
            )
        );
        _verify(structHash, sig, s.trader);

        // Effects before the external engine call; if the engine reverts, these roll back
        // and the nonce is not consumed (the intent can be retried).
        s.nonce += 1;
        s.spent += intent.amount;

        positionId = engine.openPositionFor(
            intent.amount, s.trader, intent.token, intent.isLong, intent.leverage, intent.tpPrice, intent.slPrice
        );
        emit IntentExecuted(intent.sessionId, positionId, intent.amount, intent.nonce);
    }

    /// @inheritdoc ISessionManager
    function executeClose(CloseIntent calldata intent, bytes calldata sig) external nonReentrant {
        Session storage s = _sessions[intent.sessionId];
        // Closes are allowed even after expiry (never trap a user's position), but the session must exist.
        if (s.trader == address(0)) revert Errors.SessionNotFound(intent.sessionId);
        if (intent.nonce != s.nonce) revert Errors.BadNonce(s.nonce, intent.nonce);
        if (intent.deadline < block.timestamp) revert Errors.SessionExpired(intent.deadline);

        bytes32 structHash = keccak256(
            abi.encode(CLOSE_INTENT_TYPEHASH, intent.sessionId, intent.positionId, intent.nonce, intent.deadline)
        );
        _verify(structHash, sig, s.trader);

        s.nonce += 1;
        engine.closePositionFor(s.trader, intent.positionId);
        emit CloseExecuted(intent.sessionId, intent.positionId, intent.nonce);
    }

    function _checkSession(Session storage s, uint256 nonce, uint256 deadline) internal view {
        if (!s.active) revert Errors.SessionNotFound(0);
        if (block.timestamp > s.expiry) revert Errors.SessionExpired(s.expiry);
        if (deadline < block.timestamp) revert Errors.SessionExpired(deadline);
        if (nonce != s.nonce) revert Errors.BadNonce(s.nonce, nonce);
    }

    function _verify(bytes32 structHash, bytes calldata sig, address expected) internal view {
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), sig);
        if (signer != expected) revert Errors.BadSignature();
    }

    // =========================================================================
    //                                  VIEWS
    // =========================================================================

    /// @inheritdoc ISessionManager
    function getSession(uint256 id) external view returns (Session memory) {
        return _sessions[id];
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
