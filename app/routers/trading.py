from __future__ import annotations

from fastapi import APIRouter, Depends

from app.dependencies import get_trading_session_manager, verify_api_key
from app.models.api_requests import (
    CancelStockOrderRequestModel,
    OpenSessionRequestModel,
    SubmitStockOrderRequestModel,
)
from app.services.contracts import CancelStockOrderCommand, OpenSessionCommand, SubmitStockOrderCommand
from app.services.trading_session_manager import TradingSessionManager
from app.utils.exceptions import TradingServiceException, handle_xtquant_exception
from app.utils.helpers import format_response

# ---------------------------------------------------------------------------
# 2026-10-16 补丁：盘后归档窗口的账户读缓存（默认关闭，见同目录补丁器说明）
#   窗口内：命中且未过期 ⇒ 直接返回；未命中 ⇒ 走原逻辑；**失败 ⇒ 回退上一次的值**
#   窗口外或未配置 ⇒ 与打补丁前**完全同效**
# ---------------------------------------------------------------------------
import os as _acct_cache_os
import time as _acct_cache_time
import threading as _acct_cache_lock_mod

_ACCT_CACHE_LOCK = _acct_cache_lock_mod.Lock()
_ACCT_CACHE = {}


def _acct_cache_settings():
    """返回 (启用, ttl_秒, 窗口起_分钟, 窗口止_分钟)。未配置窗口 ⇒ 不启用。"""
    win = str(_acct_cache_os.environ.get("BIGQMT_ACCOUNT_CACHE_WINDOW") or "").strip()
    if not win:
        return False, 0.0, 0, 0
    try:
        a, b = win.split("-", 1)
        sh, sm = [int(x) for x in a.strip().split(":")]
        eh, em = [int(x) for x in b.strip().split(":")]
    except Exception:
        return False, 0.0, 0, 0
    if not (0 <= sh <= 23 and 0 <= eh <= 23 and 0 <= sm <= 59 and 0 <= em <= 59):
        return False, 0.0, 0, 0
    try:
        ttl = float(_acct_cache_os.environ.get("BIGQMT_ACCOUNT_CACHE_TTL_SECONDS") or 45.0)
    except Exception:
        ttl = 45.0
    return True, max(1.0, ttl), sh * 60 + sm, eh * 60 + em


def _acct_cache_in_window(now_min, start_min, end_min):
    if start_min <= end_min:
        return start_min <= now_min <= end_min
    return now_min >= start_min or now_min <= end_min          # 跨零点


def _acct_cache_now_min():
    lt = _acct_cache_time.localtime()
    return lt.tm_hour * 60 + lt.tm_min


def _acct_cache_read(key, ttl, allow_stale):
    """返回 (payload, age_秒) 或 None。allow_stale=True 时忽略 TTL。"""
    with _ACCT_CACHE_LOCK:
        item = _ACCT_CACHE.get(key)
    if not item:
        return None
    ts, payload = item
    age = _acct_cache_time.time() - ts
    if age <= ttl or allow_stale:
        return payload, age
    return None


def _acct_cache_write(key, payload):
    with _ACCT_CACHE_LOCK:
        _ACCT_CACHE[key] = (_acct_cache_time.time(), payload)


router = APIRouter(prefix="/api/v1/trading", tags=["交易服务"])

SIDE_TO_XT = {"BUY": 23, "SELL": 24}


@router.post("/sessions")
async def open_session(
    request: OpenSessionRequestModel,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    try:
        session = trading_manager.open_session(OpenSessionCommand(request.account_id, request.account_type))
        return format_response(data=session, message="创建交易会话成功")
    except TradingServiceException as exc:
        raise handle_xtquant_exception(exc)


@router.get("/sessions/{session_id}")
async def get_session(
    session_id: str,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    try:
        return format_response(data=trading_manager.get_session(session_id), message="获取交易会话成功")
    except TradingServiceException as exc:
        raise handle_xtquant_exception(exc)


@router.delete("/sessions/{session_id}")
async def close_session(
    session_id: str,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    try:
        success = trading_manager.close_session(session_id)
        return format_response(
            data={"success": success},
            message="关闭交易会话成功" if success else "交易会话不存在",
        )
    except TradingServiceException as exc:
        raise handle_xtquant_exception(exc)


@router.get("/sessions/{session_id}/asset")
async def get_stock_asset(
    session_id: str,
    refresh: int = 0,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    _en, _ttl, _s0, _s1 = _acct_cache_settings()
    _key = "asset:" + session_id
    if _en and _acct_cache_in_window(_acct_cache_now_min(), _s0, _s1) and not refresh:
        _hit = _acct_cache_read(_key, _ttl, False)
        if _hit:
            return format_response(data=_hit[0],
                                   message="获取资产成功（缓存 %.0fs）" % _hit[1])
    try:
        _data = trading_manager.get_stock_asset(session_id)
    except TradingServiceException as exc:
        if _en and _acct_cache_in_window(_acct_cache_now_min(), _s0, _s1):
            _hit = _acct_cache_read(_key, _ttl, True)
            if _hit:
                return format_response(data=_hit[0],
                                       message="获取资产成功（回退 %.0fs 前的值）" % _hit[1])
        raise handle_xtquant_exception(exc)
    if _en and _acct_cache_in_window(_acct_cache_now_min(), _s0, _s1):
        _acct_cache_write(_key, _data)
    return format_response(data=_data, message="获取资产成功")


@router.get("/sessions/{session_id}/positions")
async def get_stock_positions(
    session_id: str,
    refresh: int = 0,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    _en, _ttl, _s0, _s1 = _acct_cache_settings()
    _key = "positions:" + session_id
    if _en and _acct_cache_in_window(_acct_cache_now_min(), _s0, _s1) and not refresh:
        _hit = _acct_cache_read(_key, _ttl, False)
        if _hit:
            return format_response(data={"items": _hit[0]},
                                   message="获取持仓成功（缓存 %.0fs）" % _hit[1])
    try:
        _data = trading_manager.get_stock_positions(session_id)
    except TradingServiceException as exc:
        if _en and _acct_cache_in_window(_acct_cache_now_min(), _s0, _s1):
            _hit = _acct_cache_read(_key, _ttl, True)
            if _hit:
                return format_response(data={"items": _hit[0]},
                                       message="获取持仓成功（回退 %.0fs 前的值）" % _hit[1])
        raise handle_xtquant_exception(exc)
    if _en and _acct_cache_in_window(_acct_cache_now_min(), _s0, _s1):
        _acct_cache_write(_key, _data)
    return format_response(data={"items": _data}, message="获取持仓成功")


@router.get("/sessions/{session_id}/orders")
async def get_stock_orders(
    session_id: str,
    cancelable_only: bool = False,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    try:
        return format_response(
            data={"items": trading_manager.get_stock_orders(session_id, cancelable_only=cancelable_only)},
            message="获取订单成功",
        )
    except TradingServiceException as exc:
        raise handle_xtquant_exception(exc)


@router.get("/sessions/{session_id}/trades")
async def get_stock_trades(
    session_id: str,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    try:
        return format_response(
            data={"items": trading_manager.get_stock_trades(session_id)},
            message="获取成交成功",
        )
    except TradingServiceException as exc:
        raise handle_xtquant_exception(exc)


@router.post("/sessions/{session_id}/orders")
async def submit_stock_order(
    session_id: str,
    request: SubmitStockOrderRequestModel,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    try:
        order = trading_manager.submit_stock_order(
            SubmitStockOrderCommand(
                session_id=session_id,
                stock_code=request.stock_code,
                side=SIDE_TO_XT[request.side],
                price_type=request.price_type,
                volume=request.volume,
                price=request.price,
                strategy_name=request.strategy_name,
                order_remark=request.order_remark,
            )
        )
        return format_response(data=order, message="下单成功")
    except TradingServiceException as exc:
        raise handle_xtquant_exception(exc)


@router.post("/sessions/{session_id}/cancel")
async def cancel_stock_order(
    session_id: str,
    request: CancelStockOrderRequestModel,
    api_key: str | None = Depends(verify_api_key),
    trading_manager: TradingSessionManager = Depends(get_trading_session_manager),
):
    try:
        success = trading_manager.cancel_stock_order(
            CancelStockOrderCommand(
                session_id=session_id,
                order_id=request.order_id,
                market=request.market,
                order_sysid=request.order_sysid,
            )
        )
        return format_response(
            data={"success": success},
            message="撤单成功" if success else "撤单失败",
        )
    except TradingServiceException as exc:
        raise handle_xtquant_exception(exc)
