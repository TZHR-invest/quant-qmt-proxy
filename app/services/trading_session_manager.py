from __future__ import annotations

import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable, Iterator

from app.config import AccountKind, Settings, XTQuantMode, XTQuantTradingAccountConfig
from app.services.contracts import CancelStockOrderCommand, OpenSessionCommand, SubmitStockOrderCommand
from app.services.trading_event_hub import TradingEventHub
from app.services.xttrader_gateway import XTQUANT_TRADER_AVAILABLE, XTTraderGateway
from app.utils.exceptions import TradingServiceException
from app.utils.helpers import normalize_stock_code, validate_stock_code
from app.utils.logger import logger


def _as_int(value: Any, default: int = 0) -> int:
    """D5 (2026-09-15): never let a payload type take down the request.

    miniQMT hands xttrader plain ints; the big-QMT RPC shim hands strings for
    some fields -- account_type arrives as "STOCK".  int("STOCK") used to raise
    ValueError inside a callback thread (swallowed by xtquant, event lost) and
    inside the HTTP handler (bare 500).  Coerce, never raise.
    """
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_float(value: Any, default: float = 0.0) -> float:
    """D5: float twin of _as_int (the shim may deliver numeric strings)."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


@dataclass
class TradingSession:
    session_id: str
    account_id: str
    account_type: str
    mode: str
    environment: str
    is_real: bool
    account_profile: str | None
    account_kind: str
    orders_enabled: bool
    opened_at_ms: int
    gateway: XTTraderGateway | None = None
    orders: dict[str, dict[str, Any]] = field(default_factory=dict)
    trades: list[dict[str, Any]] = field(default_factory=list)
    asset: dict[str, Any] | None = None
    accept_events: bool = True


class TradingSessionManager:
    CANCEL_MARKET_MAP = {
        "SH": 0,
        "SHA": 0,
        "SHANGHAI": 0,
        "0": 0,
        "SZ": 1,
        "SZA": 1,
        "SHENZHEN": 1,
        "1": 1,
    }

    # 建会话失败熔断参数：QMT 交易通道不可用时，连续失败 N 次后冷却 T 秒，
    # 冷却期内直接拒绝（不创建 XtQuantTrader 实例），防止 SDK writer 资源耗尽。
    BREAKER_FAILURE_THRESHOLD = 3
    BREAKER_COOLDOWN_SECONDS = 60

    def __init__(self, settings: Settings, event_hub: TradingEventHub | None = None):
        self.settings = settings
        self.event_hub = event_hub or TradingEventHub()
        self._lock = threading.RLock()
        self._sessions: dict[str, TradingSession] = {}
        self._mock_order_counter = 1000
        # 熔断状态: {account_id: {"failures": int, "open_until": float(epoch)}
        self._breaker: dict[str, dict[str, float | int]] = {}

    def open_session(self, command: OpenSessionCommand) -> dict[str, Any]:
        session_id = f"session_{command.account_id}_{uuid.uuid4().hex[:10]}"
        mode = self.settings.xtquant.mode
        is_real = mode in {XTQuantMode.DEV, XTQuantMode.PROD}

        account_profile_name: str | None = None
        account_kind = AccountKind.MOCK.value

        if is_real:
            profile = self._resolve_account_profile(command.account_id, command.account_type)
            account_profile_name = profile.name
            account_kind = profile.account_kind.value
            self._check_breaker(command.account_id)

        session = TradingSession(
            session_id=session_id,
            account_id=command.account_id,
            account_type=self._normalize_account_type(command.account_type),
            mode=mode.value,
            environment=mode.value,
            is_real=is_real,
            account_profile=account_profile_name,
            account_kind=account_kind,
            orders_enabled=self._orders_enabled(mode, account_kind),
            opened_at_ms=int(time.time() * 1000),
        )
        with self._lock:
            self._sessions[session_id] = session
        try:
            if is_real:
                gateway = self._connect_gateway(command.account_id, command.account_type, session_id)
                with self._lock:
                    session.gateway = gateway
            session.asset = self._query_asset(session)
        except Exception as exc:
            # 仅连接类失败计入熔断（账号配置类错误不影响）
            if is_real and isinstance(exc, TradingServiceException) and exc.error_code in {
                "XTTRADER_UNAVAILABLE",
                "TRADER_NOT_CONNECTED",
            }:
                self._record_connect_failure(command.account_id)
            with self._lock:
                existing = self._sessions.pop(session_id, None)
                if existing:
                    existing.accept_events = False
                    gateway = existing.gateway
                else:
                    gateway = None
            if gateway:
                try:
                    gateway.disconnect()
                except Exception as exc:
                    logger.warning(
                        f"failed to cleanup gateway after session open error: session_id={session_id}, error={exc}"
                    )
            raise
        if is_real:
            self._record_connect_success(command.account_id)
        logger.info(
            f"opened trading session: session_id={session_id}, account_id={session.account_id}, account_type={session.account_type}, mode={session.mode}, account_kind={session.account_kind}, orders_enabled={session.orders_enabled}"
        )
        return self._serialize_session(session)

    def close_session(self, session_id: str) -> bool:
        with self._lock:
            session = self._sessions.get(session_id)
        if not session:
            return False
        session.accept_events = False
        self.event_hub.close_session_streams(session_id)
        with self._lock:
            self._sessions.pop(session_id, None)

        disconnect_error: Exception | None = None
        disconnect_timed_out = False
        if session.gateway:
            def disconnect_worker() -> None:
                nonlocal disconnect_error
                try:
                    session.gateway.disconnect()
                except Exception as exc:
                    disconnect_error = exc
                    logger.warning(
                        f"gateway disconnect failed during session close: session_id={session_id}, account_id={session.account_id}, error={exc}"
                    )

            disconnect_thread = threading.Thread(
                target=disconnect_worker,
                daemon=True,
                name=f"xttrader-disconnect-{session_id[:8]}",
            )
            disconnect_thread.start()
            disconnect_thread.join(timeout=self.settings.xtquant.trading.disconnect_timeout_seconds)
            disconnect_timed_out = disconnect_thread.is_alive()
            if disconnect_timed_out:
                logger.warning(
                    f"gateway disconnect timed out during session close: session_id={session_id}, account_id={session.account_id}, timeout_seconds={self.settings.xtquant.trading.disconnect_timeout_seconds}"
                )
        logger.info(f"closed trading session: session_id={session_id}, account_id={session.account_id}")
        if disconnect_error:
            logger.info(
                f"session cleanup completed after disconnect error: session_id={session_id}, account_id={session.account_id}"
            )
        if disconnect_timed_out:
            logger.info(
                f"session cleanup completed with background disconnect still running: session_id={session_id}, account_id={session.account_id}"
            )
        return True

    def get_session(self, session_id: str) -> dict[str, Any]:
        return self._serialize_session(self._get_session(session_id))

    def get_stock_asset(self, session_id: str) -> dict[str, Any]:
        session = self._get_session(session_id)
        asset = self._query_asset(session)
        with self._lock:
            session.asset = asset
        return asset

    def get_stock_positions(self, session_id: str) -> list[dict[str, Any]]:
        session = self._get_session(session_id)
        if session.gateway:
            positions = session.gateway.query_stock_positions() or []
            return [self._convert_position(item) for item in positions]
        return [self._mock_position(session.account_id)]

    def get_stock_orders(self, session_id: str, cancelable_only: bool = False) -> list[dict[str, Any]]:
        session = self._get_session(session_id)
        if session.gateway:
            orders = [self._convert_order(item) for item in (session.gateway.query_stock_orders(cancelable_only) or [])]
            with self._lock:
                session.orders = {order["order_id"]: order for order in orders}
            return orders
        with self._lock:
            return list(session.orders.values())

    def get_stock_trades(self, session_id: str) -> list[dict[str, Any]]:
        session = self._get_session(session_id)
        if session.gateway:
            trades = [self._convert_trade(item) for item in (session.gateway.query_stock_trades() or [])]
            with self._lock:
                session.trades = trades
            return trades
        with self._lock:
            return list(session.trades)

    def submit_stock_order(self, command: SubmitStockOrderCommand) -> dict[str, Any]:
        session = self._get_session(command.session_id)
        if not validate_stock_code(command.stock_code):
            raise TradingServiceException(f"invalid stock code: {command.stock_code}", "INVALID_STOCK_CODE")

        if session.mode == XTQuantMode.MOCK.value:
            order = self._build_mock_order(session, command)
            self._publish_event(command.session_id, "order_update", order)
            logger.info(
                f"submitted mock order: session_id={command.session_id}, account_id={session.account_id}, stock_code={command.stock_code}, volume={command.volume}, price_type={command.price_type}"
            )
            return order

        if not session.orders_enabled:
            logger.warning(
                f"order rejected by session policy: session_id={command.session_id}, account_id={session.account_id}, mode={session.mode}, account_kind={session.account_kind}"
            )
            raise TradingServiceException(
                "order placement is disabled for this session",
                "ORDERS_DISABLED",
            )

        if not session.gateway:
            raise TradingServiceException("session is not connected to xttrader", "TRADER_NOT_CONNECTED")

        normalized_code = normalize_stock_code(command.stock_code)
        # D4 (2026-09-15): D1 only covered xttrader answering with a NEGATIVE
        # id.  The bridge does not answer at all -- it RAISES (e.g.
        # ValueError("rpc method is not allowed: order_stock") while the RPC
        # allow-list is off), and that escaped as HTTP 500 with an empty body.
        # A refusal must reach the caller as a refusal; a dead backend as 503.
        try:
            order_id = session.gateway.order_stock(
                stock_code=normalized_code,
                order_type=command.side,
                order_volume=command.volume,
                price_type=command.price_type,
                price=float(command.price or 0.0),
                strategy_name=command.strategy_name,
                order_remark=command.order_remark,
            )
        except TradingServiceException:
            raise
        except TimeoutError as exc:
            logger.error(
                f"order timed out in xttrader: session_id={command.session_id}, "
                f"account_id={session.account_id}, stock_code={command.stock_code}, "
                f"volume={command.volume}, error={exc}"
            )
            raise TradingServiceException(
                f"xttrader did not answer the order (timeout): {exc}",
                "TRADER_NOT_CONNECTED",
            ) from exc
        except Exception as exc:
            logger.error(
                f"order refused by xttrader: session_id={command.session_id}, "
                f"account_id={session.account_id}, stock_code={command.stock_code}, "
                f"volume={command.volume}, price={command.price}, "
                f"error={type(exc).__name__}: {exc}"
            )
            raise TradingServiceException(
                f"xttrader refused the order ({type(exc).__name__}): {exc}",
                "ORDER_REJECTED",
            ) from exc
        # D1 (2026-09-15): xtquant reports a NEGATIVE order id to mean "rejected"
        # (the bridge returns -1 for every order while rpc_allow_order_methods is
        # off).  Serialising that as "-1 / submitted" made REST answer "order
        # accepted" for orders that never reached the broker -- far more
        # dangerous than an outright error.
        try:
            returned_id = int(order_id)
        except (TypeError, ValueError):
            returned_id = -1
        if returned_id < 0:
            logger.error(
                f"order rejected by xttrader: session_id={command.session_id}, "
                f"account_id={session.account_id}, stock_code={command.stock_code}, "
                f"volume={command.volume}, returned={order_id!r}"
            )
            raise TradingServiceException(
                f"xttrader rejected the order (returned {order_id!r})",
                "ORDER_REJECTED",
            )
        order = {
            "account_id": session.account_id,
            "stock_code": command.stock_code,
            "instrument_name": "",
            "order_id": str(order_id),
            "order_sysid": "",
            "order_time_ms": int(time.time() * 1000),
            "order_type": command.side,
            "order_volume": command.volume,
            "price_type": command.price_type,
            "price": float(command.price or 0.0),
            "traded_volume": 0,
            "traded_price": 0.0,
            "order_status_code": 50,
            "status_msg": "submitted",
            "strategy_name": command.strategy_name,
            "order_remark": command.order_remark,
            "direction": "",
            "offset_flag": "",
            "secu_account": session.account_id,
        }
        with self._lock:
            session.orders[order["order_id"]] = order
        self._publish_event(command.session_id, "order_update", order)
        logger.info(
            f"submitted real order: session_id={command.session_id}, account_id={session.account_id}, order_id={order['order_id']}, stock_code={command.stock_code}, volume={command.volume}, price_type={command.price_type}"
        )
        return order

    def cancel_stock_order(self, command: CancelStockOrderCommand) -> bool:
        session = self._get_session(command.session_id)

        if session.mode == XTQuantMode.MOCK.value:
            if command.order_id:
                with self._lock:
                    order = session.orders.get(command.order_id)
                    if order:
                        order["order_status_code"] = 54
                        order["status_msg"] = "cancelled"
                        self._publish_event(command.session_id, "order_update", order)
            logger.info(
                f"cancelled mock order: session_id={command.session_id}, account_id={session.account_id}, order_id={command.order_id or ''}, order_sysid={command.order_sysid or ''}"
            )
            return True

        if not session.orders_enabled:
            logger.warning(
                f"cancel rejected by session policy: session_id={command.session_id}, account_id={session.account_id}, mode={session.mode}, account_kind={session.account_kind}"
            )
            raise TradingServiceException(
                "order cancellation is disabled for this session",
                "ORDERS_DISABLED",
            )

        if not session.gateway:
            raise TradingServiceException("session is not connected to xttrader", "TRADER_NOT_CONNECTED")

        # D4 (2026-09-15): same story as order_stock -- a raising bridge must
        # not surface as a bare 500.
        try:
            if command.order_id:
                result = session.gateway.cancel_order_stock(_as_int(command.order_id))
            else:
                if not command.market or not command.order_sysid:
                    raise TradingServiceException(
                        "market and order_sysid are required when cancelling by sysid",
                        "CANCEL_TARGET_REQUIRED",
                    )
                normalized_market = self._normalize_cancel_market(command.market)
                result = session.gateway.cancel_order_stock_sysid(normalized_market, command.order_sysid)
        except TradingServiceException:
            raise
        except TimeoutError as exc:
            raise TradingServiceException(
                f"xttrader did not answer the cancel (timeout): {exc}",
                "TRADER_NOT_CONNECTED",
            ) from exc
        except Exception as exc:
            logger.error(
                f"cancel refused by xttrader: session_id={command.session_id}, "
                f"account_id={session.account_id}, order_id={command.order_id}, "
                f"error={type(exc).__name__}: {exc}"
            )
            raise TradingServiceException(
                f"xttrader refused the cancel ({type(exc).__name__}): {exc}",
                "CANCEL_REJECTED",
            ) from exc

        success = result == 0
        if success and command.order_id:
            with self._lock:
                order = session.orders.get(command.order_id)
                if order:
                    order["order_status_code"] = 54
                    order["status_msg"] = "cancelled"
                    self._publish_event(command.session_id, "order_update", order)
        logger.info(
            f"cancel order result: session_id={command.session_id}, account_id={session.account_id}, success={success}, order_id={command.order_id or ''}, order_sysid={command.order_sysid or ''}"
        )
        return success

    def stream_events(
        self,
        session_id: str,
        stop_checker: Callable[[], bool] | None = None,
    ) -> Iterator[dict[str, Any]]:
        self._get_session(session_id)
        stream = self.event_hub.stream(session_id, stop_checker=stop_checker)
        if not self._get_session_if_active(session_id):
            stream.close()
        return stream

    def shutdown(self) -> None:
        with self._lock:
            session_ids = list(self._sessions.keys())
        for session_id in session_ids:
            self.close_session(session_id)

    def readiness(self) -> dict[str, Any]:
        """D3 (2026-09-15): /health/ready used to be a constant "ready", so a dead
        backend was invisible on the health endpoint.  Report what is actually
        open and connected; with no real session the honest answer is "idle",
        not "ready"."""
        with self._lock:
            sessions = list(self._sessions.values())
        real = [s for s in sessions if s.mode != XTQuantMode.MOCK.value]
        connected = [s for s in real if getattr(s.gateway, "connected", False)]
        # D6 (2026-09-15): which trader is actually wired up (bridge vs mini).
        backends = sorted({getattr(s.gateway, "backend", "none") for s in real})
        backend = backends[0] if len(backends) == 1 else ("mixed" if backends else "none")
        if not real:
            state = "idle"
        elif len(connected) == len(real):
            state = "ready"
        else:
            state = "degraded"
        return {
            "status": state,
            "sessions_total": len(sessions),
            "sessions_real": len(real),
            "sessions_connected": len(connected),
            "backend": backend,
        }

    def _connect_gateway(self, account_id: str, account_type: str, session_id: str) -> XTTraderGateway:
        if not XTQUANT_TRADER_AVAILABLE or not self.settings.xtquant.data.qmt_userdata_path:
            raise TradingServiceException(
                "xttrader is unavailable; check xtquant installation and qmt_userdata_path",
                "XTTRADER_UNAVAILABLE",
            )
        gateway = XTTraderGateway(
            qmt_userdata_path=self.settings.xtquant.data.qmt_userdata_path,
            account_id=account_id,
            account_type=account_type,
            event_handler=lambda event_type, payload: self._handle_gateway_event(session_id, event_type, payload),
        )
        try:
            gateway.connect()
        except RuntimeError as exc:
            raise TradingServiceException(str(exc), "XTTRADER_UNAVAILABLE") from exc
        except TimeoutError as exc:
            # C6 (2026-09-15): the bridge raises TimeoutError when the RPC never
            # answers.  It used to escape as a bare HTTP 500; map it to 503 so a
            # caller can tell "backend down" from "bad request".  TimeoutError is
            # a subclass of OSError, so it must be caught first.
            raise TradingServiceException(
                f"xttrader connect timed out: {exc}", "TRADER_NOT_CONNECTED"
            ) from exc
        except OSError as exc:
            raise TradingServiceException(
                f"xttrader connect failed: {exc}", "XTTRADER_UNAVAILABLE"
            ) from exc
        return gateway

    def _check_breaker(self, account_id: str) -> None:
        """熔断打开期间快速拒绝建会话，不创建 XtQuantTrader 实例。"""
        with self._lock:
            state = self._breaker.get(account_id)
            if not state:
                return
            open_until = float(state.get("open_until", 0.0))
            now = time.time()
            if open_until > now:
                raise TradingServiceException(
                    f"trading channel unavailable; cooling down for {int(open_until - now)}s",
                    "XTTRADER_UNAVAILABLE",
                )
            # 冷却期已过（此前打开过熔断），清除状态；计数中（open_until=0）不清理
            if open_until > 0:
                self._breaker.pop(account_id, None)

    def _record_connect_failure(self, account_id: str) -> None:
        """记录一次连接失败；连续失败达到阈值后打开熔断。"""
        with self._lock:
            state = self._breaker.setdefault(account_id, {"failures": 0, "open_until": 0.0})
            state["failures"] = int(state.get("failures", 0)) + 1
            if state["failures"] >= self.BREAKER_FAILURE_THRESHOLD:
                state["open_until"] = time.time() + self.BREAKER_COOLDOWN_SECONDS
                logger.warning(
                    f"circuit breaker opened for account {account_id}: "
                    f"{state['failures']} consecutive failures, cooling down {self.BREAKER_COOLDOWN_SECONDS}s"
                )

    def _record_connect_success(self, account_id: str) -> None:
        """建会话成功，清除熔断状态。"""
        with self._lock:
            self._breaker.pop(account_id, None)

    def _resolve_account_profile(self, account_id: str, account_type: str) -> XTQuantTradingAccountConfig:
        normalized_account_type = self._normalize_account_type(account_type)
        mode = self.settings.xtquant.mode

        for profile in self.settings.xtquant.trading.accounts:
            if not profile.enabled:
                continue
            if profile.account_id != account_id:
                continue
            if self._normalize_account_type(profile.account_type) != normalized_account_type:
                continue
            if mode not in profile.allowed_modes:
                continue
            if mode == XTQuantMode.DEV and profile.account_kind != AccountKind.SIMULATED:
                continue
            if mode == XTQuantMode.PROD and profile.account_kind != AccountKind.REAL:
                continue
            return profile

        raise TradingServiceException(
            f"account {account_id} is not registered for {mode.value}",
            "ACCOUNT_PROFILE_NOT_ALLOWED",
        )

    def _orders_enabled(self, mode: XTQuantMode, account_kind: str) -> bool:
        if mode == XTQuantMode.MOCK:
            return True
        if mode == XTQuantMode.DEV:
            return account_kind == AccountKind.SIMULATED.value
        if mode == XTQuantMode.PROD:
            # pytest 中的 prod 自动化始终只读；真实 prod 放单能力仍由运行时配置控制。
            return account_kind == AccountKind.REAL.value and self.settings.xtquant.trading.enable_prod_orders
        return False

    def _normalize_account_type(self, value: str | None) -> str:
        return (value or "STOCK").strip().upper()

    def _normalize_cancel_market(self, value: str | int) -> int:
        if isinstance(value, int):
            if value in {0, 1}:
                return value
            raise TradingServiceException("market must be 0/1 or SH/SZ", "INVALID_MARKET")

        normalized = str(value).strip().upper()
        if normalized in self.CANCEL_MARKET_MAP:
            return self.CANCEL_MARKET_MAP[normalized]
        raise TradingServiceException("market must be 0/1 or SH/SZ", "INVALID_MARKET")

    def _get_session(self, session_id: str) -> TradingSession:
        with self._lock:
            session = self._sessions.get(session_id)
        if not session or not session.accept_events:
            raise TradingServiceException("trading session does not exist", "SESSION_NOT_FOUND")
        return session

    def _query_asset(self, session: TradingSession) -> dict[str, Any]:
        if session.gateway:
            asset = session.gateway.query_stock_asset()
            return self._convert_asset(asset, session.account_id)
        return {
            "account_id": session.account_id,
            "cash": 950000.0,
            "frozen_cash": 50000.0,
            "market_value": 800000.0,
            "total_asset": 1800000.0,
            "fetch_balance": 900000.0,
        }

    def _serialize_session(self, session: TradingSession) -> dict[str, Any]:
        return {
            "session_id": session.session_id,
            "account_id": session.account_id,
            "account_type": session.account_type,
            "is_real": session.is_real,
            "mode": session.mode,
            "environment": session.environment,
            "account_profile": session.account_profile,
            "account_kind": session.account_kind,
            "orders_enabled": session.orders_enabled,
            "opened_at_ms": session.opened_at_ms,
        }

    def _build_mock_order(self, session: TradingSession, command: SubmitStockOrderCommand) -> dict[str, Any]:
        with self._lock:
            order_id = f"mock_{self._mock_order_counter}"
            self._mock_order_counter += 1
        order = {
            "account_id": session.account_id,
            "stock_code": command.stock_code,
            "instrument_name": f"Mock {command.stock_code}",
            "order_id": order_id,
            "order_sysid": "",
            "order_time_ms": int(time.time() * 1000),
            "order_type": command.side,
            "order_volume": command.volume,
            "price_type": command.price_type,
            "price": float(command.price or 0.0),
            "traded_volume": 0,
            "traded_price": 0.0,
            "order_status_code": 50,
            "status_msg": "submitted",
            "strategy_name": command.strategy_name,
            "order_remark": command.order_remark,
            "direction": "",
            "offset_flag": "",
            "secu_account": session.account_id,
        }
        with self._lock:
            session.orders[order_id] = order
        return order

    def _mock_position(self, account_id: str) -> dict[str, Any]:
        return {
            "account_id": account_id,
            "stock_code": "000001.SZ",
            "instrument_name": "Mock Position",
            "volume": 10000,
            "can_use_volume": 10000,
            "frozen_volume": 0,
            "on_road_volume": 0,
            "yesterday_volume": 10000,
            "open_price": 12.5,
            "avg_price": 12.5,
            "last_price": 13.2,
            "market_value": 132000.0,
            "profit_rate": 0.056,
            "direction": "LONG",
            "secu_account": account_id,
        }

    def _convert_order(self, order: Any) -> dict[str, Any]:
        return {
            "account_id": str(getattr(order, "account_id", "")),
            "stock_code": str(getattr(order, "stock_code", "")),
            "instrument_name": str(getattr(order, "instrument_name", "")),
            "order_id": str(getattr(order, "order_id", "")),
            "order_sysid": str(getattr(order, "order_sysid", "")),
            "order_time_ms": self._to_epoch_ms(getattr(order, "order_time", None)),
            "order_type": _as_int(getattr(order, "order_type", 0)),
            "order_volume": _as_int(getattr(order, "order_volume", 0)),
            "price_type": _as_int(getattr(order, "price_type", 0)),
            "price": _as_float(getattr(order, "price", 0.0)),
            "traded_volume": _as_int(getattr(order, "traded_volume", 0)),
            "traded_price": _as_float(getattr(order, "traded_price", 0.0)),
            "order_status_code": _as_int(getattr(order, "order_status", 0)),
            "status_msg": str(getattr(order, "status_msg", "")),
            "strategy_name": str(getattr(order, "strategy_name", "")),
            "order_remark": str(getattr(order, "order_remark", "")),
            "direction": str(getattr(order, "direction", "")),
            "offset_flag": str(getattr(order, "offset_flag", "")),
            "secu_account": str(getattr(order, "secu_account", "")),
        }

    def _convert_trade(self, trade: Any) -> dict[str, Any]:
        return {
            "account_id": str(getattr(trade, "account_id", "")),
            "stock_code": str(getattr(trade, "stock_code", "")),
            "instrument_name": str(getattr(trade, "instrument_name", "")),
            "order_type": _as_int(getattr(trade, "order_type", 0)),
            "traded_id": str(getattr(trade, "traded_id", "")),
            "traded_time_ms": self._to_epoch_ms(getattr(trade, "traded_time", None)),
            "traded_price": _as_float(getattr(trade, "traded_price", 0.0)),
            "traded_volume": _as_int(getattr(trade, "traded_volume", 0)),
            "traded_amount": _as_float(getattr(trade, "traded_amount", 0.0)),
            "order_id": str(getattr(trade, "order_id", "")),
            "order_sysid": str(getattr(trade, "order_sysid", "")),
            "strategy_name": str(getattr(trade, "strategy_name", "")),
            "order_remark": str(getattr(trade, "order_remark", "")),
            "direction": str(getattr(trade, "direction", "")),
            "offset_flag": str(getattr(trade, "offset_flag", "")),
            "commission": _as_float(getattr(trade, "commission", 0.0)),
            "secu_account": str(getattr(trade, "secu_account", "")),
        }

    def _convert_position(self, position: Any) -> dict[str, Any]:
        return {
            "account_id": str(getattr(position, "account_id", "")),
            "stock_code": str(getattr(position, "stock_code", "")),
            "instrument_name": str(getattr(position, "instrument_name", "")),
            "volume": _as_int(getattr(position, "volume", 0)),
            "can_use_volume": _as_int(getattr(position, "can_use_volume", 0)),
            "frozen_volume": _as_int(getattr(position, "frozen_volume", 0)),
            "on_road_volume": _as_int(getattr(position, "on_road_volume", 0)),
            "yesterday_volume": _as_int(getattr(position, "yesterday_volume", 0)),
            "open_price": _as_float(getattr(position, "open_price", 0.0)),
            "avg_price": _as_float(getattr(position, "avg_price", 0.0)),
            "last_price": _as_float(getattr(position, "last_price", 0.0)),
            "market_value": _as_float(getattr(position, "market_value", 0.0)),
            "profit_rate": _as_float(getattr(position, "profit_rate", 0.0)),
            "direction": str(getattr(position, "direction", "")),
            "secu_account": str(getattr(position, "secu_account", "")),
        }

    def _convert_asset(self, asset: Any, account_id: str) -> dict[str, Any]:
        return {
            "account_id": str(getattr(asset, "account_id", "") or account_id),
            "cash": _as_float(getattr(asset, "cash", 0.0)),
            "frozen_cash": _as_float(getattr(asset, "frozen_cash", 0.0)),
            "market_value": _as_float(getattr(asset, "market_value", 0.0)),
            "total_asset": _as_float(getattr(asset, "total_asset", 0.0)),
            "fetch_balance": _as_float(getattr(asset, "fetch_balance", 0.0)),
        }

    def _get_session_if_active(self, session_id: str) -> TradingSession | None:
        with self._lock:
            session = self._sessions.get(session_id)
            if not session or not session.accept_events:
                return None
            return session

    def _handle_gateway_event(self, session_id: str, event_type: str, payload: Any) -> None:
        session = self._get_session_if_active(session_id)
        if not session:
            logger.info(f"ignored gateway event for inactive session: session_id={session_id}, event_type={event_type}")
            return

        if event_type == "account_status":
            event_payload = {
                "account_id": str(getattr(payload, "account_id", "")),
                "account_type": _as_int(getattr(payload, "account_type", 0)),
                "status_code": _as_int(getattr(payload, "status", 0)),
            }
            self._publish_event(session_id, "account_status", event_payload)
            return
        if event_type == "stock_asset":
            asset = self._convert_asset(payload, session.account_id)
            with self._lock:
                if session.accept_events:
                    session.asset = asset
            self._publish_event(session_id, "asset_update", asset)
            return
        if event_type == "stock_order":
            order = self._convert_order(payload)
            with self._lock:
                if not session.accept_events:
                    return
                session.orders[order["order_id"]] = order
            self._publish_event(session_id, "order_update", order)
            return
        if event_type == "stock_trade":
            trade = self._convert_trade(payload)
            with self._lock:
                if not session.accept_events:
                    return
                session.trades.append(trade)
            self._publish_event(session_id, "trade_update", trade)
            return
        if event_type == "stock_position":
            self._publish_event(session_id, "position_update", self._convert_position(payload))
            return
        if event_type == "order_error":
            error_id = _as_int(getattr(payload, "error_id", 0))
            error_msg = str(getattr(payload, "error_msg", ""))
            order_id = str(getattr(payload, "order_id", ""))

            # 将错误信息回填到对应的订单记录中
            with self._lock:
                if session.accept_events and order_id in session.orders:
                    order = session.orders[order_id]
                    if order.get("order_status_code", 0) not in (54, 56):
                        order["order_status_code"] = 57
                        order["status_msg"] = error_msg or f"error_id={error_id}"

            self._publish_event(
                session_id,
                "order_error",
                {
                    "account_id": str(getattr(payload, "account_id", "")),
                    "order_id": order_id,
                    "error_id": error_id,
                    "error_msg": error_msg,
                    "strategy_name": str(getattr(payload, "strategy_name", "")),
                    "order_remark": str(getattr(payload, "order_remark", "")),
                },
            )
            return
        if event_type == "cancel_error":
            self._publish_event(
                session_id,
                "cancel_error",
                {
                    "account_id": str(getattr(payload, "account_id", "")),
                    "order_id": str(getattr(payload, "order_id", "")),
                    "order_sysid": str(getattr(payload, "order_sysid", "")),
                    "error_id": _as_int(getattr(payload, "error_id", 0)),
                    "error_msg": str(getattr(payload, "error_msg", "")),
                },
            )

    def _publish_event(self, session_id: str, event_type: str, payload: dict[str, Any]) -> None:
        self.event_hub.publish(
            session_id,
            {
                "event_time_ms": int(time.time() * 1000),
                "event_type": event_type,
                "payload": payload,
            },
        )

    def _to_epoch_ms(self, value: Any) -> int:
        if isinstance(value, datetime):
            return int(value.timestamp() * 1000)
        if value in (None, ""):
            return 0
        value_str = str(value)
        looks_like_calendar_value = len(value_str) in {8, 14} and value_str.isdigit()
        for fmt, expected_length in (("%Y%m%d%H%M%S", 14), ("%Y%m%d", 8)):
            if len(value_str) != expected_length or not value_str.isdigit():
                continue
            year = int(value_str[:4])
            if year < 2000 or year > 2100:
                continue
            try:
                return int(datetime.strptime(value_str, fmt).timestamp() * 1000)
            except (OSError, OverflowError, ValueError):
                continue
        if not looks_like_calendar_value:
            try:
                numeric = float(value)
                if numeric > 1_000_000_000_000:
                    return int(numeric)
                if numeric > 1_000_000_000:
                    return int(numeric * 1000)
            except (TypeError, ValueError):
                pass
        logger.warning(f"unable to normalize xttrader time value: raw={value!r}")
        return 0
