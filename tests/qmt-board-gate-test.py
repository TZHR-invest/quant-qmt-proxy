#!/usr/bin/env python3
# coding: utf-8
"""板块闸门单元测试（退出码即结论：0 = 全过）。

被测对象**不是**重写的一份逻辑，而是
`scripts/trade-pc-proxy-board-gate-patch.py` 里 `A_HELPER_NEW` 会插进生产文件的那一段
（`_BRIDGE_DENY_CODE_PREFIXES` + `_bridge_board_gate`）—— 测试与实现同源，
避免「测试和实现各写一份、改了一边忘了另一边」。

为什么要这个测试
----------------
1. **不配环境变量必须完全 no-op**：666/020 两个生产实例不该受这个补丁任何影响。
   这是本补丁唯一的全局风险，所以单独锁一条。
2. 北交所判定走 `normalize_stock_code` 的市场后缀（4xx/8xx/92x ⇒ `.BJ`），
   而不是靠前缀表 —— 需要证明「带后缀」与「裸代码」两条路径都被拦住。
3. 主板 + ETF/债券不能被误杀（黑名单的全部意义就在于此）。
4. **卖出永不拦**（v2）：被禁板块的卖出必须放行 —— 否则会把仓位锁死；
   方向判定要吃 `OrderSide` 枚举（str() 是 'OrderSide.BUY'，真值在 .value），不能用子串。

用法：
    python3 tests/qmt-board-gate-test.py     # 退出码 0 = 全过
"""

import importlib.util
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
PATCHER = HERE.parent / "scripts" / "trade-pc-proxy-board-gate-patch.py"

DENY = "300,301,302,688,689,43,83,87,88,92"

# (代码, 是否应被拒)
CASES_DENY_ON = [
    # 创业板（300/301/302）
    ("300750.SZ", True),
    ("300750", True),
    ("301029.SZ", True),
    ("302132.SZ", True),
    # 科创板（688/689）
    ("688111.SH", True),
    ("688111", True),
    ("689009.SH", True),
    # 北交所：裸代码经 normalize 补 .BJ
    ("920001", True),
    ("430047", True),
    ("830799", True),
    ("871981", True),
    ("889999", True),
    # 北交所：显式 .BJ 后缀（绕过 normalize 也要拦）
    ("920001.BJ", True),
    ("430047.BJ", True),
    ("830799.BJ", True),
    # 主板：必须放行
    ("600519.SH", False),
    ("601398.SH", False),
    ("603259.SH", False),
    ("605499.SH", False),
    ("000001.SZ", False),
    ("001979.SZ", False),
    ("002594.SZ", False),
    ("003816.SZ", False),
    ("600519", False),
    ("000001", False),
    # ETF / LOF / 债券：主板合法业务，不得误杀
    ("510300.SH", False),
    ("512880.SH", False),
    ("159915.SZ", False),
    ("159919.SZ", False),
    ("113050.SH", False),
    ("128036.SZ", False),
    # 沪市 B 股（900xxx）不属于任何被禁板块
    ("900901.SH", False),
]


class _EnumLike(object):
    """模拟 OrderSide 枚举：str() 给 'OrderSide.BUY'，真值在 .value（子串判据会踩空）。"""

    def __init__(self, value):
        self.value = value

    def __str__(self):
        return "OrderSide.%s" % self.value


def load_gate(env_value):
    """加载（并 exec）补丁器将要插入生产文件的那段代码。"""
    spec = importlib.util.spec_from_file_location("bgpatch", PATCHER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    tail = mod.A_HELPER_NEW.split(mod.A_HELPER, 1)[1]
    if env_value is None:
        os.environ.pop("BIGQMT_DENY_CODE_PREFIXES", None)
    else:
        os.environ["BIGQMT_DENY_CODE_PREFIXES"] = env_value
    ns = {"os": os}
    exec(compile(tail, "<board-gate>", "exec"), ns)
    return ns["_bridge_board_gate"], ns["_BRIDGE_DENY_CODE_PREFIXES"]


def main():
    fails = []

    # --- 场景 1：未配置环境变量 ⇒ 完全 no-op（666/020 的行为保证）---------------
    gate, prefixes = load_gate(None)
    if prefixes:
        fails.append("env 未设置时 _BRIDGE_DENY_CODE_PREFIXES 应为空，实际 %r" % (prefixes,))
    for code, _ in CASES_DENY_ON:
        if gate(code) is not None:
            fails.append("[no-op] env 未设置却拒绝了 %s（会误伤 666/020）" % code)

    # --- 场景 2：配置 deny 列表 ------------------------------------------------
    gate, prefixes = load_gate(DENY)
    if not prefixes:
        fails.append("env=%s 时前缀表为空" % DENY)
    for code, should_deny in CASES_DENY_ON:
        reason = gate(code, "BUY")
        if should_deny and reason is None:
            fails.append("[deny] %s 买入应被拒绝却放行" % code)
        if (not should_deny) and reason is not None:
            fails.append("[deny] %s 买入应放行却被拒: %s" % (code, reason))

    # --- 场景 2b：**卖出永不拦**（含全部被禁板块）+ 方向取值鲁棒性 ------------
    for code, _ in CASES_DENY_ON:
        for side in ("SELL", "sell", _EnumLike("SELL"), 24, None, "", "whatever"):
            reason = gate(code, side)
            if reason is not None:
                fails.append("[sell] %s side=%r 被拦（会把持仓锁死）: %s" % (code, side, reason))
    for code, should_deny in CASES_DENY_ON:
        for side in ("BUY", "buy", _EnumLike("BUY"), 23):
            reason = gate(code, side)
            if should_deny and reason is None:
                fails.append("[buy] %s side=%r 应被拒却放行（枚举/大小写判据踩空）" % (code, side))
            if (not should_deny) and reason is not None:
                fails.append("[buy] %s side=%r 应放行却被拒" % (code, side))

    # --- 场景 3：空串 / 只有逗号 ⇒ 仍视为 no-op --------------------------------
    gate, prefixes = load_gate("  ,  ")
    if prefixes:
        fails.append("env 为空白串时前缀表应折叠为空，实际 %r" % (prefixes,))
    if gate("300750.SZ") is not None:
        fails.append("env 为空白串时应 no-op")

    # --- 场景 4：缺后缀 + 非法输入不炸 ----------------------------------------
    gate, _ = load_gate(DENY)
    for weird in ("", None, "ABC", "600519.SH.X"):
        try:
            gate(weird, "BUY")
        except Exception as exc:  # noqa: BLE001
            fails.append("输入 %r 抛异常：%s: %s" % (weird, type(exc).__name__, exc))

    total = len(CASES_DENY_ON) * (1 + 7 + 4) + 4
    if fails:
        print("FAIL（%d 项失败 / 共 %d 断言）" % (len(fails), total))
        for f in fails:
            print("  - " + f)
        return 1
    print("PASS：%d 项断言全过（no-op 保证 + 买入拒绝/放行名单 + 卖出永不拦 + 方向取值鲁棒性 + 边界输入）" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
