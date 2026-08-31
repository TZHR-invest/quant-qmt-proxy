"""QMT 交易通道探活脚本

用法:
    python qmt_ready_check.py <qmt_userdata_path> <account_id> [timeout_seconds]

退出码:
    0  - READY: xttrader connect + subscribe 均成功（QMT 已登录且交易通道可用）
    1  - 未就绪（QMT 未运行 / 未登录 / 通道不可用）

供 scripts/restart-proxy.ps1 在重启代理前调用，确保 QMT 先于代理就绪。
"""
from __future__ import annotations

import sys
import time

from xtquant.xttrader import XtQuantTrader, XtQuantTraderCallback
from xtquant.xttype import StockAccount

DEFAULT_TIMEOUT = 15


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: qmt_ready_check.py <qmt_userdata_path> <account_id> [timeout_seconds]")
        return 1

    qmt_path = sys.argv[1]
    account_id = sys.argv[2]
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_TIMEOUT

    callback = XtQuantTraderCallback()
    session = (uuid.uuid4().int % 2_000_000_000) + 1  # 2026-08-31: 随机 session, 固定 session 反复 connect 导致 QMT 2.1.19.1 残留卡死
    trader = XtQuantTrader(qmt_path, session, callback)
    trader.register_callback(callback)
    trader.start()

    try:
        result = trader.connect()
        if result != 0:
            print(f"NOT_READY: connect() returned {result}")
            return 1

        # connect 成功后再订阅账号，验证交易账号已登录
        account = StockAccount(account_id, "STOCK")
        subscribe_result = trader.subscribe(account)
        if subscribe_result != 0:
            print(f"NOT_READY: subscribe() returned {subscribe_result}")
            return 1

        # 短暂停留，确认连接未立即断开
        deadline = time.time() + timeout
        while time.time() < deadline:
            if trader.connected:
                print("READY")
                return 0
            time.sleep(0.5)
        print("NOT_READY: connection dropped after subscribe")
        return 1
    finally:
        try:
            trader.stop()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
