#!/usr/bin/env python3
# coding: utf-8
"""代理侧「账户板块闸门」补丁器（trade-pc，幂等，CRLF 安全）。

为什么需要
----------
第三个 QMT 账户（666656292986 / 王白凡02）**暂时没有创业板/科创板/北交所权限**，而下游
（stock_selection 的 advisor、看板、数据管道）是全市场选股的。不加闸门 ⇒ 这些标的的单子
被柜台判废单（噪音 + 让「下单成功」的判据失真）；将来权限开通后又要放开 ⇒ 必须做成
**可配置、可即时关闭**的闸门，而不是散在下游各处的过滤。

落点（唯一收口，实测）
----------------------
    app/services/trading_session_manager.py :: TradingSessionManager.submit_stock_order()
      `gateway.order_stock(`        全文恰好 1 处
      `normalize_stock_code(command.stock_code)` 全文恰好 1 处
        ⇒ 闸门插在这一行之后即可覆盖全部下单请求；撤单（cancel_stock_order）不需要闸门。
      方向字段 `command.side`（`SubmitStockOrderCommand.side: OrderSide`，trading_models.py:29/30/86）。

开关（按实例，走 NSSM 服务环境变量）
------------------------------------
    BIGQMT_DENY_CODE_PREFIXES = "688,689,43,83,87,88,92,11,12,13"
      * 2026-10-12：2986 开通创业板 ⇒ 去掉 300,301,302（科创板/北交所/可转债仍拦）
      * 未设置 / 空字符串 ⇒ 闸门**完全不生效**（666/020 行为与打补丁前同效）
      * 数字前缀命中 ⇒ TradingServiceException(..., "BOARD_NOT_ALLOWED")
      * 市场后缀 BJ ⇒ 一律拒绝（北交所）
    由 scripts/qmt-install-proxy-instance.ps1 写进服务环境（-DenyCodePrefixes）。

为什么是黑名单 + 只拦买入（v2）
--------------------------------
只拦**买入**：卖出永不拦 —— 已持有的票（转托管进来、或权限变更前买入的）必须能卖掉，
拦掉卖出等于把仓位锁死。方向取自 `command.side`（OrderSide 枚举，取 .value，不用子串判据）；
side 未知 ⇒ 放行。

为什么是黑名单而不是白名单
--------------------------
柜台才是最终权威。白名单会误杀主板的 ETF/债券单（那是合法业务），而黑名单漏拦只产生
一张废单 —— 风险不对称，所以选择「宁漏不误杀」。

为什么同时改 exceptions.py
--------------------------
错误码走 elif 链，**未登记的码会落到 else ⇒ HTTP 400**（实测 app/utils/exceptions.py）。
本补丁把 BOARD_NOT_ALLOWED 并进 422 分支（与 ORDER_REJECTED / CANCEL_REJECTED 同级），
保证下游把它当「拒单」处理，而不是当成「坏请求/代码 bug」。

生效范围与回退
--------------
* 服务在**启动时**读代码 ⇒ 新实例（8003）首次启动即带上；666/020 在下次服务重启时带上
  （它们无该环境变量 ⇒ 行为不变）。⚠️ 「源码已打补丁」≠「服务已生效」。
* 即时关闭不需要回滚文件：把服务的 BIGQMT_DENY_CODE_PREFIXES 置空并重启该服务。
* 回滚：`--revert` 从 `.bak-board-gate-<时间戳>` 还原（两文件同时还原）。

用法（在 trade-pc 上跑）
------------------------
    python trade-pc-proxy-board-gate-patch.py --check
    python trade-pc-proxy-board-gate-patch.py --apply
    python trade-pc-proxy-board-gate-patch.py --revert
"""

import argparse
import glob
import hashlib
import os
import shutil
import sys
import time

PROXY_DIR = r"G:\qmt_projects\quant-qmt-proxy"
TARGETS = [
    "app/services/trading_session_manager.py",
    "app/utils/exceptions.py",
]

MARK = "BIGQMT_BOARD_GATE_PATCH"

# --------------------------------------------------------------------------- #
# 逐文件的锚点与插入内容（\n 由 patch() 按该文件自身的换行风格展开）
# --------------------------------------------------------------------------- #

# ① trading_session_manager.py：import os
A_IMPORT = "\nimport threading\n"
A_IMPORT_NEW = "\nimport os\nimport threading\n"

# ② trading_session_manager.py：模块级开关 + 闸门函数（插在 import 块之后）
A_HELPER = "\nfrom app.utils.logger import logger\n"
A_HELPER_NEW = """
from app.utils.logger import logger

# --- {mark} (2026-09-28, v2) -------------------------------------------------
# 按实例的「禁止板块」前缀表，经 NSSM 服务环境变量注入（见
# scripts/qmt-install-proxy-instance.ps1）。空 ⇒ 闸门是 no-op，即 666/020 的既有行为。
# ⚠️ v2（2026-09-28 晚）：**只拦买入**。卖出永不拦 —— 已持有的票（转托管进来、或权限
#    变更前买的）必须能卖掉；拦掉卖出 = 把仓位锁死，而漏拦只多一张废单（不对称）。
_BRIDGE_DENY_CODE_PREFIXES = tuple(
    p.strip()
    for p in str(os.environ.get("BIGQMT_DENY_CODE_PREFIXES", "")).split(",")
    if p.strip()
)


def _bridge_side_value(side) -> str:
    \"\"\"把 OrderSide 枚举或字符串统一成 'BUY'/'SELL'（取 .value，不用子串判据）。\"\"\"
    return str(getattr(side, "value", side) or "").strip().upper()


def _bridge_is_buy(side) -> bool:
    \"\"\"只认明确的买入：'BUY' 或 xtconstant.STOCK_BUY(23)；其余（含 SELL/None）都不是。\"\"\"
    value = _bridge_side_value(side)
    return value == "BUY" or value == "23"


def _bridge_board_gate(normalized_code: str, side=None):
    \"\"\"账户无权限的板块**买入** ⇒ 返回拒绝原因；其余一律 None。

    刻意「黑名单 + 单向」：柜台是最终权威。白名单会误杀主板的 ETF/债券单；拦卖出会把
    仓位锁死；漏拦只产生一张废单 —— 风险不对称，所以选择「宁漏不误杀」。
    side 未知（None / 未来新增值）⇒ 放行。
    \"\"\"
    if not _BRIDGE_DENY_CODE_PREFIXES:
        return None
    if not _bridge_is_buy(side):
        return None
    code = str(normalized_code or "").strip().upper()
    digits, _, market = code.partition(".")
    if market == "BJ":
        return "board not allowed for this account: %s (BSE)" % code
    for prefix in _BRIDGE_DENY_CODE_PREFIXES:
        if digits.startswith(prefix):
            return "board not allowed for this account: %s (denied prefix %s)" % (
                code,
                prefix,
            )
    return None
# --- end {mark} -------------------------------------------------------------
""".format(mark=MARK)

# ③ trading_session_manager.py：下单前的实际检查
A_ORDER = "\n        normalized_code = normalize_stock_code(command.stock_code)\n"
A_ORDER_NEW = """
        normalized_code = normalize_stock_code(command.stock_code)
        # {mark}: 板块闸门（本实例的账户权限窄于全市场时启用；未配置则为 no-op）
        _gate_reason = _bridge_board_gate(normalized_code, command.side)
        if _gate_reason:
            logger.warning(
                f"order refused by board gate: session_id={{command.session_id}}, "
                f"account_id={{session.account_id}}, code={{normalized_code}}, "
                f"reason={{_gate_reason}}"
            )
            raise TradingServiceException(_gate_reason, "BOARD_NOT_ALLOWED")
""".format(mark=MARK)

# ④ exceptions.py：把 BOARD_NOT_ALLOWED 并进 422 分支
A_HTTP = '\n        elif exc.error_code in {"ORDER_REJECTED", "CANCEL_REJECTED"}:\n'
# 注意：本处必须带上 MARK 注释 —— 幂等判据是「文件里有没有 MARK」，少了它第二次
# --check 会误报「锚点命中 0 次」（本地真实字节干跑实测踩到）。
A_HTTP_NEW = (
    "\n        # {mark}: 板块闸门拒绝按 422（拒单）返回，而不是落到 else 的 400\n"
    "        elif exc.error_code in "
    '{{"ORDER_REJECTED", "CANCEL_REJECTED", "BOARD_NOT_ALLOWED"}}:\n'
).format(mark=MARK)

PATCHES = {
    "app/services/trading_session_manager.py": [
        ("import-os", A_IMPORT, A_IMPORT_NEW),
        ("helper", A_HELPER, A_HELPER_NEW),
        ("order-gate", A_ORDER, A_ORDER_NEW),
    ],
    "app/utils/exceptions.py": [
        ("http-422", A_HTTP, A_HTTP_NEW),
    ],
}


def md5_of(path):
    with open(path, "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def newline_of(raw):
    return b"\r\n" if raw.count(b"\r\n") > raw.count(b"\n") // 2 else b"\n"


def expand(text, nl):
    return text.replace("\n", nl.decode("ascii")).encode("utf-8")


def already(raw):
    return MARK.encode("ascii") in raw


def rel_for(path):
    """把绝对路径映射回 TARGETS 里的相对路径（按 basename 匹配，仅 3 个目标）。"""
    base = os.path.basename(path)
    for t in TARGETS:
        if os.path.basename(t) == base:
            return t
    raise SystemExit("内部错误：%s 不在 TARGETS 内" % path)


def check_file(path, verbose=True):
    """返回 (需要打的补丁名列表, 错误列表)。"""
    raw = read_bytes(path)
    todo, errs = [], []
    if already(raw):
        if verbose:
            print("    [已打补丁] %s" % path)
        return [], []
    for name, old, _new in PATCHES[rel_for(path)]:
        needle = expand(old, newline_of(raw))
        n = raw.count(needle)
        if n != 1:
            errs.append("%s: 锚点 %s 命中 %d 次（要求恰好 1 次）" % (path, name, n))
        else:
            todo.append(name)
    return todo, errs


def patch_one(path, apply=False, stamp=""):
    raw = read_bytes(path)
    if already(raw):
        return "skip", md5_of(path)
    nl = newline_of(raw)
    rel = rel_for(path)
    todo, errs = check_file(path, verbose=False)
    if errs:
        for e in errs:
            print("    ERROR " + e)
        return "error", md5_of(path)
    for name, old, new in PATCHES[rel]:
        needle = expand(old, nl)
        if raw.count(needle) != 1:
            print("    ERROR %s: 锚点 %s 不再唯一（竞态？）" % (path, name))
            return "error", md5_of(path)
        raw = raw.replace(needle, expand(new, nl), 1)
    # 语法自检：补丁后必须仍是合法 Python（不 import，只 compile）
    try:
        compile(raw.decode("utf-8"), path, "exec")
    except SyntaxError as exc:
        print("    ERROR %s: 补丁后语法不合法：%s" % (path, exc))
        return "error", md5_of(path)
    if not apply:
        return "would-patch", hashlib.md5(raw).hexdigest()
    bak = path + ".bak-board-gate-" + stamp
    shutil.copy2(path, bak)
    with open(path, "wb") as fh:
        fh.write(raw)
    return "patched", md5_of(path)


def revert_one(path):
    baks = sorted(glob.glob(path + ".bak-board-gate-*"))
    if not baks:
        return "no-backup"
    shutil.copy2(baks[-1], path)
    return "reverted<-" + os.path.basename(baks[-1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只报告，不写盘")
    ap.add_argument("--apply", action="store_true", help="打补丁（先备份）")
    ap.add_argument("--revert", action="store_true", help="从最近一次备份还原")
    ap.add_argument("--proxy-dir", default=PROXY_DIR)
    args = ap.parse_args()
    if not (args.check or args.apply or args.revert):
        ap.error("需要 --check / --apply / --revert 之一")

    if not os.path.isdir(args.proxy_dir):
        print("ERROR: 代理目录不存在: %s" % args.proxy_dir)
        return 2

    paths = [os.path.join(args.proxy_dir, *t.split("/")) for t in TARGETS]
    for p in paths:
        if not os.path.isfile(p):
            print("ERROR: 目标文件不存在: %s" % p)
            return 2

    stamp = time.strftime("%Y%m%d%H%M%S")
    rc = 0
    if args.revert:
        print("=== revert ===")
        for p in paths:
            print("  %s -> %s" % (revert_one(p), p))
        return 0

    print("=== %s ===" % ("apply" if args.apply else "check"))
    for p in paths:
        before = md5_of(p)
        todo, errs = check_file(p, verbose=False)
        if errs:
            for e in errs:
                print("  ERROR " + e)
            rc = 1
            continue
        if not todo:
            print("  %s: 已是最新（md5 %s）" % (os.path.basename(p), before))
            continue
        print("  %s: 待打 %s（当前 md5 %s）" % (os.path.basename(p), ",".join(todo), before))
        if args.apply:
            state, after = patch_one(p, apply=True, stamp=stamp)
            print("    -> %s，md5 %s（备份 .bak-board-gate-%s）" % (state, after, stamp))
            if state != "patched":
                rc = 1
        else:
            state, after = patch_one(p, apply=False)
            print("    -> %s（预计 md5 %s）" % (state, after))
            if state != "would-patch":
                rc = 1
    if not args.apply and rc == 0:
        print("（--check 未写盘；确认无误后加 --apply）")
    return rc


if __name__ == "__main__":
    sys.exit(main())
