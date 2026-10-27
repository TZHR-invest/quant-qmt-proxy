#!/usr/bin/env python3
# coding: utf-8
"""QMT 代理「查询通道」探针 —— 补上 bridge 探针看不见的那一半（2026-10-27 事故产物）。

为什么需要
----------
2026-10-27 的故障形态是：**桥（bridge_rpc_probe）全程 READY，但 xttrader 断了**
（`POST /api/v1/trading/sessions` 一直 503 `XTTRADER_UNAVAILABLE`，下游报
「交易日持仓/资产接口不可用」）。而 `qmt-proxy-watchdog.sh` 的判据是「桥通 ⇒ 健康」，
于是**整场故障期间看门狗一声不响**，只能靠人肉发现。

本探针读代理自己的 `/health/ready`，把那半个盲区变成可判据的东西。

关键语义（readiness() 的实现，勿混）
  · `status=idle`     = 没有真实会话（**正常空闲**，也可能意味着「建不出会话」）
  · `status=ready`    = 有会话且都连着
  · `status=degraded` = 有会话但没全连上
  · `circuit_open`    = 正处于**连接失败熔断**中的账户列表（2026-10-27 新增字段）
  ⇒ **只看 status 分不出「空闲」和「挂掉」**（挂掉时根本建不出会话，也是 idle）；
     真正的判据是 `circuit_open` 非空。

退出码（即结论，调用方不要用子串判断）
  0 = 健康
  1 = 查询通道故障（有账户处于熔断中）
  2 = backend 不是 bridge（配置了 PYTHONPATH 却回落成 mini —— 正是"静默降级"形态）
  3 = 探针自身错误（拿不到 /health/ready）

用法（在 trade-pc 的 Windows 侧跑，用代理 venv 的 python）::

    python.exe qmt-proxy-ready-probe.py --port 8003 --expect-bridge
"""
import argparse
import http.client
import json
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def fetch(host: str, port: int, timeout: float):
    """直接用 http.client —— **不走系统代理**。

    ⚠️ 本机（trade-pc）开着系统代理（127.0.0.1:7890），裸 urllib/requests 探本机端口
    会被接走并报 10061；`http.client` 直连则不受影响。AGENTS.md 里说的
    「一律用 System32\\curl.exe --noproxy '*'」是同一个坑的另一条解法。
    """
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("GET", "/health/ready")
        resp = conn.getresponse()
        raw = resp.read()
        if resp.status != 200:
            return None, f"HTTP {resp.status}"
        body = json.loads(raw)
        return body.get("data", body), None
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--expect-bridge", action="store_true",
                    help="该实例配了 PYTHONPATH（期望 bigqmt shim）时传，backend=mini 即异常")
    ap.add_argument("--timeout", type=float, default=5.0)
    args = ap.parse_args()

    try:
        data, err = fetch(args.host, args.port, args.timeout)
    except Exception as exc:                      # 探针本身失败要显式暴露
        print(f"PROBE_ERROR {type(exc).__name__}: {exc}")
        return 3
    if data is None:
        print(f"PROBE_ERROR {err}")
        return 3

    status = data.get("status")
    backend = data.get("backend")
    circuit_open = list(data.get("circuit_open") or [])
    print("status={} backend={} circuit_open={} sessions_real={} breaker={}".format(
        status, backend, circuit_open,
        data.get("sessions_real"), data.get("breaker_failures")))

    if circuit_open:
        print("VERDICT=QUERY_CHANNEL_DOWN")
        return 1

    # `none` = 还没有会话（空转是正常的，不是降级）；只有真的接上 mini 才算降级
    if args.expect_bridge and backend not in ("bridge", "none"):
        print("VERDICT=WRONG_BACKEND")
        return 2

    print("VERDICT=OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
