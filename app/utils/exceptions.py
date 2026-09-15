"""
异常处理模块
"""
from typing import Any, Dict, Optional

from fastapi import HTTPException, status


class XTQuantException(Exception):
    """xtquant相关异常基类"""
    def __init__(self, message: str, error_code: Optional[str] = None):
        self.message = message
        self.error_code = error_code
        super().__init__(self.message)


class DataServiceException(XTQuantException):
    """数据服务异常"""
    pass


class TradingServiceException(XTQuantException):
    """交易服务异常"""
    pass


class ConfigurationException(XTQuantException):
    """配置异常"""
    pass


class AuthenticationException(XTQuantException):
    """认证异常"""
    pass


def create_error_response(
    message: str,
    error_code: Optional[str] = None,
    status_code: int = status.HTTP_500_INTERNAL_SERVER_ERROR,
    details: Optional[Dict[str, Any]] = None
) -> HTTPException:
    """创建标准错误响应"""
    error_detail = {
        "message": message,
        "error_code": error_code or "INTERNAL_ERROR"
    }
    if details:
        error_detail.update(details)
    
    return HTTPException(
        status_code=status_code,
        detail=error_detail
    )


def handle_xtquant_exception(exc: XTQuantException) -> HTTPException:
    """处理xtquant异常"""
    if isinstance(exc, DataServiceException):
        if exc.error_code in ["EMPTY_SYMBOLS", "INVALID_SYMBOLS", "INVALID_SUBSCRIPTION_COUNT"]:
            status_code = status.HTTP_422_UNPROCESSABLE_ENTITY
        elif exc.error_code == "MAX_SUBSCRIPTIONS_EXCEEDED":
            status_code = status.HTTP_429_TOO_MANY_REQUESTS
        elif exc.error_code == "WHOLE_QUOTE_DISABLED":
            status_code = status.HTTP_403_FORBIDDEN
        elif exc.error_code == "FEATURE_NOT_SUPPORTED":
            status_code = status.HTTP_501_NOT_IMPLEMENTED
        elif exc.error_code in ["XTDATA_UNAVAILABLE", "SUBSCRIPTION_FAILED"]:
            status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        else:
            status_code = status.HTTP_400_BAD_REQUEST
        
        return create_error_response(
            message=exc.message,
            error_code=exc.error_code or "DATA_SERVICE_ERROR",
            status_code=status_code
        )
    elif isinstance(exc, TradingServiceException):
        if exc.error_code == "ORDERS_DISABLED":
            status_code = status.HTTP_403_FORBIDDEN
        elif exc.error_code in {"ORDER_REJECTED", "CANCEL_REJECTED"}:
            # D1/D4 (2026-09-15): xttrader answered with a negative order id, OR
            # the gateway raised instead of answering (bridge allow-list off).
            # 422 = the broker side said no; 503 = we could not reach it at all.
            status_code = status.HTTP_422_UNPROCESSABLE_ENTITY
        elif exc.error_code == "SESSION_NOT_FOUND":
            status_code = status.HTTP_404_NOT_FOUND
        elif exc.error_code == "ACCOUNT_PROFILE_NOT_ALLOWED":
            status_code = status.HTTP_403_FORBIDDEN
        elif exc.error_code in {"XTTRADER_UNAVAILABLE", "TRADER_NOT_CONNECTED"}:
            status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        else:
            status_code = status.HTTP_400_BAD_REQUEST
        return create_error_response(
            message=exc.message,
            error_code=exc.error_code or "TRADING_SERVICE_ERROR",
            status_code=status_code
        )
    elif isinstance(exc, AuthenticationException):
        return create_error_response(
            message=exc.message,
            error_code=exc.error_code or "AUTHENTICATION_ERROR",
            status_code=status.HTTP_401_UNAUTHORIZED
        )
    elif isinstance(exc, ConfigurationException):
        return create_error_response(
            message=exc.message,
            error_code=exc.error_code or "CONFIGURATION_ERROR",
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
        )
    else:
        return create_error_response(
            message=exc.message,
            error_code=exc.error_code or "UNKNOWN_ERROR"
        )
