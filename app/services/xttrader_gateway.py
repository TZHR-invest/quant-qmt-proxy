from __future__ import annotations

import uuid
from typing import Any, Callable

from app.utils.logger import logger

try:
    from xtquant import xtconstant
    from xtquant.xttrader import XtQuantTrader, XtQuantTraderCallback
    from xtquant.xttype import StockAccount

    XTQUANT_TRADER_AVAILABLE = True
except ImportError:
    xtconstant = None
    XtQuantTrader = None
    XtQuantTraderCallback = object
    StockAccount = None
    XTQUANT_TRADER_AVAILABLE = False



import uuid

# --- 2026-08-31 回退: 固定 session 池导致 QMT 2.1.19.1 session 残留卡死 ---
# 固定 session 反复 connect/disconnect 后, QMT 客户端内部状态残留, 后续握手超时 (connect -1)。
# 实测: 固定池 session (6764649xx) connect=-1, 随机 session connect=0 秒连。
# 恢复 8/28 前的随机 session; down_queue 由 qmt-downqueue-clean.sh 每周清理。

def _next_fixed_session(account_id: str) -> int:
    return (uuid.uuid4().int % 2_000_000_000) + 1

ACCOUNT_TYPE_MAP = {
    "SECURITY": "STOCK",
    "STOCK": "STOCK",
    "CREDIT": "CREDIT",
    "FUTURE": "FUTURE",
    "FUTURE_OPTION": "FUTURE_OPTION",
    "STOCK_OPTION": "STOCK_OPTION",
    "HUGANGTONG": "HUGANGTONG",
    "SHENGANGTONG": "SHENGANGTONG",
    "NEW3BOARD": "NEW3BOARD",
    "INCOME_SWAP": "INCOME_SWAP",
}


class TraderCallbackBridge(XtQuantTraderCallback):
    def __init__(
        self,
        event_handler: Callable[[str, Any], None] | None = None,
        on_disconnect: Callable[[], None] | None = None,
    ):
        self._event_handler = event_handler
        self._on_disconnect = on_disconnect

    def _emit(self, event_type: str, payload: Any) -> None:
        if self._event_handler is not None:
            self._event_handler(event_type, payload)

    def on_connected(self):
        logger.info("xttrader 已连接")

    def on_disconnected(self):
        logger.warning("xttrader 连接断开")
        # D2 (2026-09-15): this used to only log.  Nothing ever flipped
        # `connected` back to False, so after the underlying link died REST kept
        # answering 200 with all-zero data instead of failing -- the "200 + all
        # zeros" incident.  The callback now marks the gateway disconnected.
        if self._on_disconnect is not None:
            try:
                self._on_disconnect()
            except Exception as exc:  # never raise back into xtquant's thread
                logger.error(f"on_disconnected hook failed: {exc}")

    def on_account_status(self, status):
        self._emit("account_status", status)

    def on_stock_asset(self, asset):
        self._emit("stock_asset", asset)

    def on_stock_order(self, order):
        self._emit("stock_order", order)

    def on_stock_trade(self, trade):
        self._emit("stock_trade", trade)

    def on_stock_position(self, position):
        self._emit("stock_position", position)

    def on_order_error(self, order_error):
        logger.error(f"xttrader 下单失败: {getattr(order_error, 'error_msg', order_error)}")
        self._emit("order_error", order_error)

    def on_cancel_error(self, cancel_error):
        logger.error(f"xttrader 撤单失败: {getattr(cancel_error, 'error_msg', cancel_error)}")
        self._emit("cancel_error", cancel_error)


class XTTraderGateway:
    def __init__(
        self,
        qmt_userdata_path: str,
        account_id: str,
        account_type: str = "STOCK",
        event_handler: Callable[[str, Any], None] | None = None,
    ):
        if not XTQUANT_TRADER_AVAILABLE:
            raise RuntimeError("xtquant.xttrader 不可用")
        if not qmt_userdata_path:
            raise RuntimeError("未配置 xtquant.data.qmt_userdata_path")

        normalized_account_type = ACCOUNT_TYPE_MAP.get(account_type.upper())
        if not normalized_account_type:
            raise RuntimeError(f"不支持的账户类型: {account_type}")

        self.qmt_userdata_path = qmt_userdata_path
        self.account_id = account_id
        self.account_type = normalized_account_type
        self.session = _next_fixed_session(account_id)
        self.callback = TraderCallbackBridge(
            event_handler=event_handler,
            on_disconnect=self._mark_disconnected,
        )
        self.trader: XtQuantTrader | None = None
        self.account: StockAccount | None = None
        self.connected = False

    @property
    def backend(self) -> str:
        """D6 (2026-09-15): name the trader implementation actually loaded.

        `xtquant.mode` says prod/dev -- that is a licence/environment flag and
        says nothing about which trader object got wired up.  miniQMT runs the
        classic in-process xttrader; the big-QMT route swaps in the
        xtquant_big_convert shim (module bigqmt_signal_trader.*) that talks to
        the full client over RPC.  Health must report the latter as "bridge"
        so a silent fallback cannot hide.
        """
        if self.trader is None:
            return "none"
        module = (type(self.trader).__module__ or "").lower()
        return "bridge" if "bigqmt" in module else "mini"

    def _mark_disconnected(self) -> None:
        """D2: invoked from xtquant's callback thread when the link drops."""
        if self.connected:
            logger.warning(
                f"xttrader 标记为未连接: account_id={self.account_id}, session={self.session}"
            )
        self.connected = False

    def connect(self) -> None:
        self.trader = XtQuantTrader(self.qmt_userdata_path, self.session, self.callback)
        self.trader.register_callback(self.callback)
        self.trader.start()
        # 2026-08-31 事故: 高负载下 QMT 客户端握手 >3s, 默认超时导致 connect -1。
        # 调大到 10s, 给握手足够时间 (2.1.19.1 新建连接握手排队/优先级低)。
        try:
            self.trader.set_timeout(10)
        except Exception:
            pass
        logger.info(
            f"xttrader connecting: account_id={self.account_id}, account_type={self.account_type}, session={self.session}"
        )
        result = self.trader.connect()
        if result != 0:
            self.disconnect()
            raise RuntimeError(f"xttrader.connect() 返回 {result}")
        self.account = StockAccount(self.account_id, self.account_type)
        subscribe_result = self.trader.subscribe(self.account)
        if subscribe_result != 0:
            self.disconnect()
            raise RuntimeError(f"xttrader.subscribe() 返回 {subscribe_result}")
        self.connected = True
        logger.info(
            f"xttrader ready: account_id={self.account_id}, account_type={self.account_type}, session={self.session}"
        )

    def disconnect(self) -> None:
        if self.trader and self.account:
            try:
                self.trader.unsubscribe(self.account)
            except Exception:
                pass
        if self.trader:
            try:
                self.trader.stop()
            except Exception:
                pass
        self.connected = False
        logger.info(
            f"xttrader disconnected: account_id={self.account_id}, account_type={self.account_type}, session={self.session}"
        )

    def ensure_connected(self) -> None:
        if not self.trader or not self.account or not self.connected:
            raise RuntimeError("xttrader 尚未连接")

    def order_stock(
        self,
        stock_code: str,
        order_type: int,
        order_volume: int,
        price_type: int,
        price: float,
        strategy_name: str = "",
        order_remark: str = "",
    ) -> int:
        self.ensure_connected()
        return self.trader.order_stock(
            self.account,
            stock_code,
            order_type,
            order_volume,
            price_type,
            price,
            strategy_name,
            order_remark,
        )

    def cancel_order_stock(self, order_id: int) -> int:
        self.ensure_connected()
        return self.trader.cancel_order_stock(self.account, order_id)

    def cancel_order_stock_sysid(self, market: str | int, order_sysid: str) -> int:
        self.ensure_connected()
        return self.trader.cancel_order_stock_sysid(self.account, market, order_sysid)

    def query_stock_asset(self) -> Any:
        self.ensure_connected()
        return self.trader.query_stock_asset(self.account)

    def query_stock_orders(self, cancelable_only: bool = False) -> Any:
        self.ensure_connected()
        return self.trader.query_stock_orders(self.account, cancelable_only=cancelable_only)

    def query_stock_trades(self) -> Any:
        self.ensure_connected()
        return self.trader.query_stock_trades(self.account)

    def query_stock_positions(self) -> Any:
        self.ensure_connected()
        return self.trader.query_stock_positions(self.account)
