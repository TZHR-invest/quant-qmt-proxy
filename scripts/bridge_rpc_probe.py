# -*- coding: utf-8 -*-
"""Readiness probe for the big-QMT bridge backend (2026-09-15).

The bridge has no local "connection" object: the trading capability lives in a
strategy running inside XtItClient.exe and is reached over Redis.  So the only
honest readiness test is a real round trip -- exactly what
quant-qmt-proxy/scripts/qmt_ready_check.py does for miniQMT, but over the bridge.

The account is passed explicitly (NOT taken from the client config module),
because one machine serves several accounts and the module can only name one.

Usage:  bridge_rpc_probe.py <account_id> [timeout_seconds]
Exit 0 and print "READY ..." when the strategy answers; 1 otherwise.
"""

from __future__ import print_function

import sys


def main(argv):
    if len(argv) < 2:
        print("usage: bridge_rpc_probe.py <account_id> [timeout_seconds]")
        return 2
    account_id = argv[1]
    timeout = 6.0
    if len(argv) > 2:
        try:
            timeout = float(argv[2])
        except ValueError:
            print("NOT_READY: bad timeout %r" % (argv[2],))
            return 2

    # The client lives in the bridge checkout; keep this probe self-contained so
    # it works from a scheduled task with no PYTHONPATH.
    for path in (r"C:\bridge-client\bridge\src", r"C:\bridge-client"):
        if path not in sys.path:
            sys.path.insert(0, path)

    try:
        from bigqmt_signal_trader.xtquant_compat import BigQmtRpcClient
        client = BigQmtRpcClient(account_id=account_id, timeout_seconds=timeout)
        pong = client.call("ping", timeout_seconds=timeout)
    except Exception as exc:  # noqa: BLE001 - any failure is "not ready"
        print("NOT_READY: %s: %s" % (type(exc).__name__, exc))
        return 1

    if not isinstance(pong, dict) or not pong.get("pong"):
        print("NOT_READY: unexpected ping response %r" % (pong,))
        return 1
    got = str(pong.get("account_id") or "")
    if got != account_id:
        print("NOT_READY: account mismatch: bridge=%r expected=%r" % (got, account_id))
        return 1
    print(
        "READY account_id=%s version=%s allow_order_methods=%s server_time=%s"
        % (got, pong.get("version"), pong.get("allow_order_methods"), pong.get("server_time"))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
