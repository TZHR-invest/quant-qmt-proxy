# -*- coding: utf-8 -*-
"""Append one readiness+freshness line for the big-QMT bridge (2026-09-15).

The open question before switching quant-qmt-proxy onto the bridge is whether it
serves LIVE quotes during a session, not just the stale pre-open snapshot.  A
scheduled task runs this every few minutes and appends to
logs/bridge-session-<yyyyMMdd>.log, so the trading day leaves evidence behind
instead of relying on someone watching.

Usage: bridge_session_sample.py <account_id> [symbol]
"""

from __future__ import print_function

import datetime
import io
import os
import sys

LOG_DIR = r"G:\qmt_projects\quant-qmt-proxy\logs"


def append(line):
    try:
        if not os.path.isdir(LOG_DIR):
            os.makedirs(LOG_DIR)
        path = os.path.join(LOG_DIR, "bridge-session-%s.log" % datetime.date.today().strftime("%Y%m%d"))
        with io.open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception as exc:  # noqa: BLE001
        print("log write failed: %s" % exc)
    print(line)


def main(argv):
    account_id = argv[1] if len(argv) > 1 else "666810082889"
    symbol = argv[2] if len(argv) > 2 else "000001.SZ"
    for path in (r"C:\bridge-client\bridge\src", r"C:\bridge-client"):
        if path not in sys.path:
            sys.path.insert(0, path)

    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    parts = [stamp, "acct=%s" % account_id]
    try:
        from bigqmt_signal_trader.xtquant_compat import BigQmtRpcClient, StockAccount
        from bigqmt_signal_trader import xtquant_compat as compat

        client = BigQmtRpcClient(account_id=account_id, timeout_seconds=8.0)
        pong = client.call("ping", timeout_seconds=8.0)
        parts.append("ping=%s" % ("OK" if pong.get("pong") else "BAD"))
        parts.append("ver=%s" % pong.get("version"))

        trader = compat.BigQmtXtTrader(account_id=account_id, timeout_seconds=8.0)
        tick = compat.xtdata.get_full_tick([symbol]) or {}
        row = tick.get(symbol) or {}
        parts.append("tick=%s" % (row.get("timetag") or "?"))
        parts.append("last=%s" % (row.get("lastPrice")))
        parts.append("status=%s" % (row.get("stockStatus")))
        asset = trader.query_stock_asset(StockAccount(account_id, "STOCK"))
        parts.append("total=%s" % getattr(asset, "total_asset", None))
        positions = trader.query_stock_positions(StockAccount(account_id, "STOCK")) or []
        parts.append("pos=%d" % len(positions))
    except Exception as exc:  # noqa: BLE001
        parts.append("ERROR=%s: %s" % (type(exc).__name__, str(exc)[:160]))
    append(" | ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
