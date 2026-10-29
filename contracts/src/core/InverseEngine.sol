// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IInverseEngine} from "../interfaces/IInverseEngine.sol";
import {IInverseVault} from "../interfaces/IInverseVault.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {Errors} from "../libraries/Errors.sol";
import {Governed} from "../libraries/Governed.sol";

/// @title  InverseEngine
/// @notice Position lifecycle for leveraged longs/shorts against the InverseVault. Collateral is held
///         here; the vault reserves each position's capped max payout. PnL is a clamped function of the
///         oracle TWAP move; losses and borrow fees flow to the vault, open/close fees to the distributor.
contract InverseEngine is IInverseEngine, Governed, ReentrancyGuard {
    IPriceOracle public immutable oracle;
    IInverseVault public immutable vault;
    IFeeDistributor public immutable feeDistributor;
    address public sessionManager;

    // ---- Constant guards ----
    uint256 public constant NOTIONAL_CAP_BPS = 200; // position notional ≤ 2% of pair WBNB reserve

    // ---- Hard bounds on guardian-settable params ----
    uint256 public constant MAX_FEE_BPS = 300;
    uint256 public constant MIN_HOLD_MAX = 1 hours;
    uint256 public constant LIQ_THRESHOLD_LO = 8000;
    uint256 public constant LIQ_THRESHOLD_HI = 9900;
    uint256 public constant KEEPER_REWARD_MAX = 1000;
    uint256 public constant BORROW_BASE_MAX = 100;
    uint256 public constant OI_CAP_MAX = 2000;
    uint256 public constant PAYOUT_CAP_LO = 100;
    uint256 public constant PAYOUT_CAP_HI = 500;
    uint256 public constant PAUSE_DURATION = 72 hours;

    // ---- Params ----
    uint256 public openFeeBps = 100;
    uint256 public closeFeeBps = 100;
    uint256 public minPosition = 0.01 ether;
    uint256 public maxPosition = 0.5 ether; // Stage 0
    uint256 public minHold = 60;
    uint256 public liqThresholdBps = 9500;
    uint256 public keeperRewardBps = 500;
    uint256 public borrowBasePerHourBps = 1; // 0.01%/hr at 100% utilization
    uint256 public maxOiPerTokenBps = 500;
    uint256 public payoutCapBps = 300; // Stage 0
    uint8 public maxLeverageEnabled = 2; // Stage 0

    uint256 public pauseOpensUntil;

    uint256 public nextId = 1;
    mapping(uint256 => Position) private _positions;
    mapping(address => uint256) public tokenOi; // open notional per token (BNB)

    event PositionOpened(
        uint256 indexed id,
        address indexed trader,
        address indexed token,
        bool isLong,
        uint8 leverage,
        uint256 collateral,
        uint256 entryPrice,
        uint256 maxPayout
    );
    event PositionClosed(uint256 indexed id, int256 pnl, uint256 borrowFee, uint256 closeFee, uint256 traderOut);
    event PositionLiquidated(uint256 indexed id, address indexed keeper, uint256 keeperReward, uint256 toVault, uint256 badDebt);
    event TpSlSet(uint256 indexed id, uint256 tpPrice, uint256 slPrice);
    event ParamsChanged();
    event OpensPaused(uint256 until);
    event SessionManagerSet(address sessionManager);

    modifier whenOpensNotPaused() {
        if (block.timestamp < pauseOpensUntil) revert Errors.OpensPaused();
        _;
    }

    constructor(address oracle_, address vault_, address feeDistributor_, address guardian_)
        Governed(guardian_)
    {
        if (oracle_ == address(0) || vault_ == address(0) || feeDistributor_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        oracle = IPriceOracle(oracle_);
        vault = IInverseVault(vault_);
        feeDistributor = IFeeDistributor(feeDistributor_);
    }

    // =========================================================================
    //                                 OPEN
    // =========================================================================

    /// @inheritdoc IInverseEngine
    function openPosition(address token, bool isLong, uint8 leverage, uint256 tpPrice, uint256 slPrice)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        return _open(msg.sender, msg.value, token, isLong, leverage, tpPrice, slPrice);
    }

    /// @inheritdoc IInverseEngine
    function openPositionFor(
        address trader,
        address token,
        bool isLong,
        uint8 leverage,
        uint256 tpPrice,
        uint256 slPrice
    ) external payable nonReentrant returns (uint256 id) {
        if (msg.sender != sessionManager) revert Errors.NotSessionManager(msg.sender);
        return _open(trader, msg.value, token, isLong, leverage, tpPrice, slPrice);
    }

    function _open(
        address trader,
        uint256 value,
        address token,
        bool isLong,
        uint8 leverage,
        uint256 tpPrice,
        uint256 slPrice
    ) internal whenOpensNotPaused returns (uint256 id) {
        if (oracle.halted(token)) revert Errors.Halted(token);
        if (leverage != 2 && leverage != 5 && leverage != 10) revert Errors.BadLeverage(leverage);
        if (leverage > maxLeverageEnabled) revert Errors.LeverageNotEnabled(leverage, maxLeverageEnabled);
        if (value < minPosition) revert Errors.PositionTooSmall(value, minPosition);
        if (value > maxPosition) revert Errors.PositionTooLarge(value, maxPosition);

        oracle.snapshot(token);
        uint256 entryPrice = oracle.getPrice(token);

        uint256 openFee = (value * openFeeBps) / 10_000;
        uint256 collateral = value - openFee;
        uint256 notional = collateral * leverage;

        uint256 reserveWbnb = oracle.pairReserveWbnb(token);
        uint256 notionalCap = (reserveWbnb * NOTIONAL_CAP_BPS) / 10_000;
        if (notional > notionalCap) revert Errors.NotionalCapExceeded(notional, notionalCap);

        uint256 oiCap = (vault.nav() * maxOiPerTokenBps) / 10_000;
        if (tokenOi[token] + notional > oiCap) revert Errors.OiCapExceeded(tokenOi[token] + notional, oiCap);

        uint256 maxPayout = _maxPayout(collateral, leverage, reserveWbnb);

        _validateTpSl(isLong, entryPrice, tpPrice, slPrice);

        vault.reserve(maxPayout);
        tokenOi[token] += notional;

        id = nextId++;
        _positions[id] = Position({
            trader: trader,
            token: token,
            isLong: isLong,
            leverage: leverage,
            isOpen: true,
            collateral: collateral,
            entryPrice: entryPrice,
            maxPayout: maxPayout,
            openTimestamp: block.timestamp,
            lastFeeTimestamp: block.timestamp,
            accruedBorrowFee: 0,
            tpPrice: tpPrice,
            slPrice: slPrice
        });

        if (openFee > 0) feeDistributor.distribute{value: openFee}();

        emit PositionOpened(id, trader, token, isLong, leverage, collateral, entryPrice, maxPayout);
    }

    function _maxPayout(uint256 collateral, uint8 leverage, uint256 reserveWbnb)
        internal
        view
        returns (uint256)
    {
        uint256 leverageCap = collateral * (leverage - 1);
        uint256 poolCap = (vault.nav() * payoutCapBps) / 10_000;
        uint256 notionalCap = (reserveWbnb * NOTIONAL_CAP_BPS) / 10_000;
        uint256 liquidityCap = notionalCap > collateral ? notionalCap - collateral : 0;
        uint256 m = leverageCap < poolCap ? leverageCap : poolCap;
        return m < liquidityCap ? m : liquidityCap;
    }

    // =========================================================================
    //                                 CLOSE
    // =========================================================================

    /// @inheritdoc IInverseEngine
    function closePosition(uint256 id) external nonReentrant {
        Position storage p = _positions[id];
        if (!p.isOpen) revert Errors.PositionNotOpen(id);

        oracle.snapshot(p.token);
        uint256 price = oracle.getPrice(p.token);

        if (msg.sender != p.trader) {
            // Keepers may only close when a TP/SL trigger is hit.
            if (!_tpSlHit(p, price)) revert Errors.TpSlNotHit(id);
        }
        if (block.timestamp < p.openTimestamp + minHold) {
            revert Errors.HoldingPeriod(p.openTimestamp, minHold);
        }

        _close(id, price);
    }

    /// @inheritdoc IInverseEngine
    function closePositionFor(address trader, uint256 id) external nonReentrant {
        if (msg.sender != sessionManager) revert Errors.NotSessionManager(msg.sender);
        Position storage p = _positions[id];
        if (!p.isOpen) revert Errors.PositionNotOpen(id);
        if (p.trader != trader) revert Errors.NotPositionOwner(trader, p.trader);

        oracle.snapshot(p.token);
        uint256 price = oracle.getPrice(p.token);
        if (block.timestamp < p.openTimestamp + minHold) {
            revert Errors.HoldingPeriod(p.openTimestamp, minHold);
        }
        _close(id, price);
    }

    function _close(uint256 id, uint256 price) internal {
        Position storage p = _positions[id];
        address trader = p.trader;
        address token = p.token;
        uint256 collateral = p.collateral;
        uint256 maxPayout = p.maxPayout;
        uint256 notional = collateral * p.leverage;

        int256 pnl = _pnl(p, price);
        uint256 borrowFee = _borrowFee(p);

        // Effects first.
        p.isOpen = false;
        tokenOi[token] -= notional;

        uint256 closeFee;
        uint256 traderOut;

        if (pnl >= 0) {
            uint256 profit = uint256(pnl);
            // Pull profit from the vault into the engine, then disburse.
            if (profit > 0) vault.payTrader(address(this), profit);
            uint256 net = collateral + profit;
            net = net > borrowFee ? net - borrowFee : 0;
            closeFee = (net * closeFeeBps) / 10_000;
            traderOut = net - closeFee;
            vault.release(maxPayout);
            if (borrowFee > 0) vault.receiveLoss{value: borrowFee}();
            if (closeFee > 0) feeDistributor.distribute{value: closeFee}();
            if (traderOut > 0) _sendBnb(trader, traderOut);
        } else {
            uint256 loss = uint256(-pnl);
            uint256 toVault = loss + borrowFee;
            uint256 badDebt;
            if (toVault > collateral) {
                badDebt = toVault - collateral;
                toVault = collateral;
            }
            uint256 net = collateral - toVault; // collateral - loss - borrowFee (post-cap)
            closeFee = (net * closeFeeBps) / 10_000;
            traderOut = net - closeFee;
            vault.release(maxPayout);
            if (toVault > 0) vault.receiveLoss{value: toVault}();
            if (badDebt > 0) vault.absorbBadDebt(badDebt);
            if (closeFee > 0) feeDistributor.distribute{value: closeFee}();
            if (traderOut > 0) _sendBnb(trader, traderOut);
        }

        emit PositionClosed(id, pnl, borrowFee, closeFee, traderOut);
    }

    // =========================================================================
    //                               LIQUIDATE
    // =========================================================================

    /// @inheritdoc IInverseEngine
    function liquidate(uint256 id) external nonReentrant {
        _liquidate(id, msg.sender);
    }

    /// @notice Self-call entrypoint used by `liquidateBatch` so the real keeper (not the engine)
    ///         receives the reward while each liquidation stays individually reverting/isolated.
    function liquidateFor(uint256 id, address rewardTo) external nonReentrant {
        if (msg.sender != address(this)) revert Errors.NotEngine(msg.sender);
        _liquidate(id, rewardTo);
    }

    /// @notice Liquidates many positions in one tx (Gelato/keeper resolver). Non-liquidatable or
    ///         already-closed ids are skipped rather than reverting the whole batch.
    function liquidateBatch(uint256[] calldata ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            try this.liquidateFor(ids[i], msg.sender) {} catch {}
        }
    }

    function _liquidate(uint256 id, address rewardTo) internal {
        Position storage p = _positions[id];
        if (!p.isOpen) revert Errors.PositionNotOpen(id);

        oracle.snapshot(p.token);
        uint256 price = oracle.getPrice(p.token);

        int256 pnl = _pnl(p, price);
        uint256 borrowFee = _borrowFee(p);
        uint256 collateral = p.collateral;

        uint256 lossPlusFee = pnl >= 0 ? borrowFee : uint256(-pnl) + borrowFee;
        if (lossPlusFee * 10_000 < liqThresholdBps * collateral) revert Errors.NotLiquidatable(id);

        uint256 notional = collateral * p.leverage;
        p.isOpen = false;
        tokenOi[p.token] -= notional;

        uint256 keeperReward = (collateral * keeperRewardBps) / 10_000;
        if (keeperReward > collateral) keeperReward = collateral;
        uint256 toVault = collateral - keeperReward;
        uint256 badDebt = lossPlusFee > collateral ? lossPlusFee - collateral : 0;

        vault.release(p.maxPayout);
        if (toVault > 0) vault.receiveLoss{value: toVault}();
        if (badDebt > 0) vault.absorbBadDebt(badDebt);
        if (keeperReward > 0) _sendBnb(rewardTo, keeperReward);

        emit PositionLiquidated(id, rewardTo, keeperReward, toVault, badDebt);
    }

    // =========================================================================
    //                                 TP/SL
    // =========================================================================

    /// @inheritdoc IInverseEngine
    function setTpSl(uint256 id, uint256 tpPrice, uint256 slPrice) external {
        Position storage p = _positions[id];
        if (!p.isOpen) revert Errors.PositionNotOpen(id);
        if (msg.sender != p.trader) revert Errors.NotPositionOwner(msg.sender, p.trader);
        _validateTpSl(p.isLong, p.entryPrice, tpPrice, slPrice);
        p.tpPrice = tpPrice;
        p.slPrice = slPrice;
        emit TpSlSet(id, tpPrice, slPrice);
    }

    function _validateTpSl(bool isLong, uint256 entry, uint256 tp, uint256 sl) internal pure {
        if (tp != 0) {
            if (isLong ? tp <= entry : tp >= entry) revert Errors.InvalidTpSl();
        }
        if (sl != 0) {
            if (isLong ? sl >= entry : sl <= entry) revert Errors.InvalidTpSl();
        }
    }

    function _tpSlHit(Position storage p, uint256 price) internal view returns (bool) {
        if (p.isLong) {
            if (p.tpPrice != 0 && price >= p.tpPrice) return true;
            if (p.slPrice != 0 && price <= p.slPrice) return true;
        } else {
            if (p.tpPrice != 0 && price <= p.tpPrice) return true;
            if (p.slPrice != 0 && price >= p.slPrice) return true;
        }
        return false;
    }

    // =========================================================================
    //                                 MATH
    // =========================================================================

    function _pnl(Position storage p, uint256 price) internal view returns (int256) {
        int256 entry = int256(p.entryPrice);
        int256 delta = int256(price) - entry;
        if (!p.isLong) delta = -delta;
        int256 pnl = (int256(p.collateral) * int256(uint256(p.leverage)) * delta) / entry;

        int256 maxP = int256(p.maxPayout);
        int256 minP = -int256(p.collateral);
        if (pnl > maxP) return maxP;
        if (pnl < minP) return minP;
        return pnl;
    }

    function _borrowFee(Position storage p) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - p.lastFeeTimestamp;
        if (elapsed == 0) return p.accruedBorrowFee;
        uint256 notional = p.collateral * p.leverage;
        uint256 util = vault.utilizationBps(); // 0..10000
        // fee = notional * base * (util/10000)^2 * (elapsed/3600), with the division performed last so
        // sub-bps hourly rates at normal (low) utilization are not truncated to zero.
        //   denom = 10000 (base bps) * 1e8 (util^2 scale) * 3600 (sec/hour)
        uint256 fee = (notional * borrowBasePerHourBps * util * util * elapsed) / (10_000 * 1e8 * 3600);
        return p.accruedBorrowFee + fee;
    }

    // =========================================================================
    //                                 VIEWS
    // =========================================================================

    /// @inheritdoc IInverseEngine
    function getPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @inheritdoc IInverseEngine
    function getTokenOi(address token) external view returns (uint256) {
        return tokenOi[token];
    }

    /// @inheritdoc IInverseEngine
    function getUnrealized(uint256 id) external view returns (int256 pnl, uint256 borrowFee) {
        Position storage p = _positions[id];
        if (!p.isOpen) return (0, 0);
        uint256 price = oracle.getPrice(p.token);
        pnl = _pnl(p, price);
        borrowFee = _borrowFee(p);
    }

    /// @inheritdoc IInverseEngine
    function isLiquidatable(uint256 id) external view returns (bool) {
        Position storage p = _positions[id];
        if (!p.isOpen) return false;
        uint256 price = oracle.getPrice(p.token);
        int256 pnl = _pnl(p, price);
        uint256 borrowFee = _borrowFee(p);
        uint256 lossPlusFee = pnl >= 0 ? borrowFee : uint256(-pnl) + borrowFee;
        return lossPlusFee * 10_000 >= liqThresholdBps * p.collateral;
    }

    /// @inheritdoc IInverseEngine
    function previewOpen(address token, bool isLong, uint8 leverage, uint256 amount)
        external
        view
        returns (Preview memory pv)
    {
        pv.entryPrice = oracle.getPrice(token);
        pv.openFee = (amount * openFeeBps) / 10_000;
        pv.collateral = amount - pv.openFee;
        uint256 reserveWbnb = oracle.pairReserveWbnb(token);
        pv.maxPayout = _maxPayout(pv.collateral, leverage, reserveWbnb);
        // liq move = liqThreshold / (10000 * leverage)
        uint256 moveBps = (liqThresholdBps) / leverage; // fraction of entry * 1e... in bps of entry
        if (isLong) {
            pv.liqPrice = pv.entryPrice - (pv.entryPrice * moveBps) / 10_000;
        } else {
            pv.liqPrice = pv.entryPrice + (pv.entryPrice * moveBps) / 10_000;
        }
        uint256 util = vault.utilizationBps();
        pv.borrowRatePerHourBps = (borrowBasePerHourBps * util * util) / (10_000 * 10_000);
    }

    // =========================================================================
    //                                 GUARDIAN
    // =========================================================================

    function setSessionManager(address sm) external onlyGuardian {
        if (sessionManager != address(0)) revert Errors.AlreadyInitialized();
        if (sm == address(0)) revert Errors.ZeroAddress();
        sessionManager = sm;
        emit SessionManagerSet(sm);
    }

    function pauseOpens() external onlyGuardian {
        pauseOpensUntil = block.timestamp + PAUSE_DURATION;
        emit OpensPaused(pauseOpensUntil);
    }

    function unpauseOpens() external onlyGuardian {
        pauseOpensUntil = 0;
        emit OpensPaused(0);
    }

    function setFees(uint256 open_, uint256 close_) external onlyGuardian {
        if (open_ > MAX_FEE_BPS || close_ > MAX_FEE_BPS) revert Errors.OutOfBounds(open_, 0, MAX_FEE_BPS);
        openFeeBps = open_;
        closeFeeBps = close_;
        emit ParamsChanged();
    }

    function setPositionLimits(uint256 min_, uint256 max_) external onlyGuardian {
        if (min_ == 0 || max_ < min_) revert Errors.OutOfBounds(max_, min_, type(uint256).max);
        minPosition = min_;
        maxPosition = max_;
        emit ParamsChanged();
    }

    function setMaxPosition(uint256 max_) external onlyGuardian {
        if (max_ < minPosition) revert Errors.OutOfBounds(max_, minPosition, type(uint256).max);
        maxPosition = max_;
        emit ParamsChanged();
    }

    function setMinHold(uint256 s) external onlyGuardian {
        if (s > MIN_HOLD_MAX) revert Errors.OutOfBounds(s, 0, MIN_HOLD_MAX);
        minHold = s;
        emit ParamsChanged();
    }

    function setLiqThreshold(uint256 bps) external onlyGuardian {
        if (bps < LIQ_THRESHOLD_LO || bps > LIQ_THRESHOLD_HI) {
            revert Errors.OutOfBounds(bps, LIQ_THRESHOLD_LO, LIQ_THRESHOLD_HI);
        }
        liqThresholdBps = bps;
        emit ParamsChanged();
    }

    function setKeeperReward(uint256 bps) external onlyGuardian {
        if (bps > KEEPER_REWARD_MAX) revert Errors.OutOfBounds(bps, 0, KEEPER_REWARD_MAX);
        keeperRewardBps = bps;
        emit ParamsChanged();
    }

    function setBorrowBase(uint256 bps) external onlyGuardian {
        if (bps > BORROW_BASE_MAX) revert Errors.OutOfBounds(bps, 0, BORROW_BASE_MAX);
        borrowBasePerHourBps = bps;
        emit ParamsChanged();
    }

    function setMaxOiPerToken(uint256 bps) external onlyGuardian {
        if (bps > OI_CAP_MAX) revert Errors.OutOfBounds(bps, 0, OI_CAP_MAX);
        maxOiPerTokenBps = bps;
        emit ParamsChanged();
    }

    function setPayoutCapBps(uint256 bps) external onlyGuardian {
        if (bps < PAYOUT_CAP_LO || bps > PAYOUT_CAP_HI) {
            revert Errors.OutOfBounds(bps, PAYOUT_CAP_LO, PAYOUT_CAP_HI);
        }
        payoutCapBps = bps;
        emit ParamsChanged();
    }

    function setMaxLeverageEnabled(uint8 lev) external onlyGuardian {
        if (lev != 2 && lev != 5 && lev != 10) revert Errors.BadLeverage(lev);
        maxLeverageEnabled = lev;
        emit ParamsChanged();
    }

    // =========================================================================
    //                                 INTERNAL
    // =========================================================================

    function _sendBnb(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert Errors.EthTransferFailed();
    }

    /// @dev Accepts BNB from the vault when settling winning positions (profit is pulled in, then
    ///      disbursed to the trader in the same call). Not used for any other purpose.
    receive() external payable {}
}
