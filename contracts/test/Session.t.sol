// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {ISessionManager} from "../src/interfaces/ISessionManager.sol";
import {Errors} from "../src/libraries/Errors.sol";

contract SessionTest is Base {
    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    function setUp() public override {
        super.setUp();
        engine.setBorrowBase(0);
        _fundVault(1000 ether);
        _warmV2();
        signer = vm.addr(signerPk);
        vm.deal(signer, 100 ether);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(signer);
        id = session.createSession{value: 10 ether}(1 ether, 1 hours);
    }

    function _signTrade(ISessionManager.TradeIntent memory it) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                session.TRADE_INTENT_TYPEHASH(),
                it.sessionId,
                it.token,
                it.isLong,
                it.leverage,
                it.amount,
                it.tpPrice,
                it.slPrice,
                it.nonce,
                it.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", session.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _tradeIntent(uint256 id, uint256 nonce) internal view returns (ISessionManager.TradeIntent memory) {
        return ISessionManager.TradeIntent({
            sessionId: id,
            token: address(token),
            isLong: true,
            leverage: 2,
            amount: 1 ether,
            tpPrice: 0,
            slPrice: 0,
            nonce: nonce,
            deadline: block.timestamp + 10 minutes
        });
    }

    function test_createSession() public {
        uint256 id = _create();
        ISessionManager.Session memory s = session.getSession(id);
        assertEq(s.trader, signer);
        assertEq(s.budget, 10 ether);
        assertEq(s.maxPerTrade, 1 ether);
        assertTrue(s.active);
    }

    function test_executeIntent_anyoneCanRelay() public {
        uint256 id = _create();
        ISessionManager.TradeIntent memory it = _tradeIntent(id, 0);
        bytes memory sig = _signTrade(it);

        vm.prank(keeper); // relayer is just a gas payer
        uint256 posId = session.executeIntent(it, sig);

        assertEq(engine.getPosition(posId).trader, signer); // position owned by the signer
        ISessionManager.Session memory s = session.getSession(id);
        assertEq(s.nonce, 1);
        assertEq(s.spent, 1 ether);
    }

    function test_executeIntent_badSignatureReverts() public {
        uint256 id = _create();
        ISessionManager.TradeIntent memory it = _tradeIntent(id, 0);
        bytes memory sig = _signTrade(it);
        it.amount = 0.5 ether; // tamper after signing
        vm.prank(keeper);
        vm.expectRevert(Errors.BadSignature.selector);
        session.executeIntent(it, sig);
    }

    function test_executeIntent_perTradeCap() public {
        uint256 id = _create();
        ISessionManager.TradeIntent memory it = _tradeIntent(id, 0);
        it.amount = 2 ether; // > maxPerTrade 1
        bytes memory sig = _signTrade(it);
        vm.prank(keeper);
        vm.expectRevert();
        session.executeIntent(it, sig);
    }

    function test_revoke_blocksExecution() public {
        uint256 id = _create();
        vm.prank(signer);
        session.revokeSession(id);
        ISessionManager.TradeIntent memory it = _tradeIntent(id, 0);
        bytes memory sig = _signTrade(it);
        vm.prank(keeper);
        vm.expectRevert();
        session.executeIntent(it, sig);
    }

    function test_withdrawUnspent() public {
        uint256 id = _create();
        ISessionManager.TradeIntent memory it = _tradeIntent(id, 0);
        session.executeIntent(it, _signTrade(it)); // spends 1

        uint256 before = signer.balance;
        vm.prank(signer);
        session.withdrawUnspent(id);
        assertEq(signer.balance - before, 9 ether); // 10 budget - 1 spent
    }

    function test_closeIntent() public {
        uint256 id = _create();
        ISessionManager.TradeIntent memory it = _tradeIntent(id, 0);
        uint256 posId = session.executeIntent(it, _signTrade(it));

        vm.warp(block.timestamp + 61);
        pair.sync();

        ISessionManager.CloseIntent memory ci = ISessionManager.CloseIntent({
            sessionId: id,
            positionId: posId,
            nonce: 1,
            deadline: block.timestamp + 10 minutes
        });
        bytes32 structHash = keccak256(
            abi.encode(session.CLOSE_INTENT_TYPEHASH(), ci.sessionId, ci.positionId, ci.nonce, ci.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", session.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        vm.prank(keeper);
        session.executeClose(ci, abi.encodePacked(r, s, v));
        assertFalse(engine.getPosition(posId).isOpen);
    }
}
