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



import hashlib
import threading

# --- down_queue 防复发: 固定 session 池 (2026-08-29) ---
# 背景: 每次 uuid 随机 session 都会让 QMT 在 userdata_mini 生成 lock_down_queue_win_<session>
#       且 2.1.19.1 不再自动清理, 导致每天数百个垃圾文件堆积。
# 方案: 按 account_id 确定性派生固定 session, 轮询复用, 不再产生新 lock 文件。
#       池大小 8 = 全量日志实测单端口并发连接峰值 5 (020: 08-08/08-27/08-28; 666: 08-25)
#       + 3 缓冲 (覆盖新增下游客户端/重启风暴), 每账号最多 8 个固定 lock 文件。
# 线程安全: proxy 为 uvicorn 多线程服务, 并发 POST /sessions 会同时进入本函数,
#           计数器读-改-写必须加锁, 否则并发线程可能拿到相同 slot 导致 session 冲突。
_SESSION_POOL_SIZE = 8
_session_pool_counter = 0
_session_pool_lock = threading.Lock()

def _next_fixed_session(account_id: str) -> int:
    global _session_pool_counter
    digest = int(hashlib.md5(account_id.encode()).hexdigest()[:8], 16)
    base = (digest % 1_900_000_000) + 1
    with _session_pool_lock:
        slot = _session_pool_counter % _SESSION_POOL_SIZE
        _session_pool_counter += 1
    return base + slot

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
    def __init__(self, event_handler: Callable[[str, Any], None] | None = None):
        self._event_handler = event_handler

    def _emit(self, event_type: str, payload: Any) -> None:
        if self._event_handler is not None:
            self._event_handler(event_type, payload)

    def on_connected(self):
        logger.info("xttrader 已连接")

    def on_disconnected(self):
        logger.warning("xttrader 连接断开")

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
        self.callback = TraderCallbackBridge(event_handler=event_handler)
        self.trader: XtQuantTrader | None = None
        self.account: StockAccount | None = None
        self.connected = False

    def connect(self) -> None:
        self.trader = XtQuantTrader(self.qmt_userdata_path, self.session, self.callback)
        self.trader.register_callback(self.callback)
        self.trader.start()
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
