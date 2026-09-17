"""健康检查路由。"""

from datetime import datetime

from fastapi import APIRouter, Depends

from app.config import Settings, get_settings
from app.dependencies import get_trading_session_manager
from app.utils.helpers import format_response

router = APIRouter(prefix="/health", tags=["健康检查"])


@router.get("/")
async def health_check(settings: Settings = Depends(get_settings)):
    """健康检查接口。"""

    return format_response(
        data={
            "status": "healthy",
            "app_name": settings.app.name,
            "app_version": settings.app.version,
            "xtquant_mode": settings.xtquant.mode.value,
            "timestamp": datetime.now().isoformat(),
        },
        message="服务运行正常",
    )


@router.get("/ready")
async def readiness_check(
    manager=Depends(get_trading_session_manager),
    settings: Settings = Depends(get_settings),
):
    """就绪检查：报告真实后端状态，而不是恒 ready。

    D3 (2026-09-15): 以前无条件返回 ready，桥/连接死了在健康接口上完全看不见。
    没有会话时返回 idle —— 进程活着但还没有交易通道，不该谎报 ready。
    """

    data = manager.readiness()
    # D6 (2026-09-15): `backend` used to carry xtquant.mode (prod/dev), which
    # says nothing about WHICH trader is wired up -- a silent fall back to
    # miniQMT looked identical to the intended bridge.  readiness() now owns
    # `backend` (bridge/mini/none); the licence mode keeps its own key.
    data["xtquant_mode"] = settings.xtquant.mode.value
    return format_response(
        data=data,
        message="服务已就绪" if data["status"] == "ready" else f"交易通道未就绪（{data['status']}）",
    )


@router.get("/live")
async def liveness_check():
    """存活检查接口。"""

    return format_response(
        data={"status": "alive"},
        message="服务存活",
    )
