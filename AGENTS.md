# AGENTS.md

## Quick start

```cmd
python -m venv .venv && .venv\Scripts\activate.bat
pip install -r requirements.txt
```

## Run

```cmd
set APP_MODE=mock && set APP_SERVERS=all && python run.py
# or: python start.py --mode mock --servers all
```

`APP_SERVERS=rest|grpc|all` controls which servers start.

## Test

```cmd
.venv\Scripts\python.exe -m pytest tests/unit -q --xt-mode=mock
```

xt-mode options: `mock|dev|prod`. Default is `mock`. See `tests/README.md` for real-environment test setup.

## Architecture

- **`app/`**: FastAPI + gRPC app. Entrypoint `app/main.py`.
- **`app/routers/`**: REST endpoints (`data.py`, `trading.py`, `health.py`, `websocket.py`).
- **`app/services/`**: Business logic. `xtdata_gateway.py` wraps `xtquant.xtdata`; `xttrader_gateway.py` wraps `xtquant.xttrader`.
- **`app/grpc_services/`**: gRPC service implementations.
- **`proto/` + `generated/`**: Protobuf definitions and generated code. Regen with `python scripts/generate_proto.py --mode generate`.
- **`tests/unit/`**: All maintained tests. Test README at `tests/README.md`.

## Config

Three config files (YAML), merged in order:
1. `config.yml` — repo default
2. `config.local.yml` — runtime local overrides (git-ignored)
3. `config.test.local.yml` — test-only (git-ignored)

Key env overrides: `APP_MODE`, `APP_SERVERS`, `APP_HOST`, `APP_PORT`, `QMT_USERDATA_PATH`, `APP_ENABLE_PROD_ORDERS`, `APP_API_KEYS`.

## API conventions

- **Auth**: `Authorization: Bearer <key>`. Keys per mode in `config.yml` (e.g. `mock-api-key-001`, `prod-api-key-001`).
- **Response envelope**: `{"success": bool, "message": str, "code": int, "data": ..., "timestamp": str}`.
- **Side mapping**: `BUY=23`, `SELL=24` (xtconstant).
- **Account types**: `STOCK`, `CREDIT`, `FUTURE`, etc. Normalized via `ACCOUNT_TYPE_MAP` in `xttrader_gateway.py`.
- **Stock codes**: e.g. `000001.SZ`, `600000.SH`.

## Modes

| Mode | xtquant | Orders |
|------|---------|--------|
| mock | no QMT | fake |
| dev | real xtquant, simulated account | allowed |
| prod | real xtquant, real account | requires `enable_prod_orders: true` |

## Key gotchas

- **Python 3.10–3.13 required** (not 3.7, not 3.9).
- **API key** goes in `Authorization: Bearer` header, **not** `X-API-Key`.
- xtdata connect runs async in background thread; initial queries may return empty.
- Before dev/prod, create `config.local.yml` with `qmt_userdata_path` (MiniQMT: `userdata_mini`, QMT: `userdata`) and registered accounts.
- `enable_prod_orders: false` by default; prod sessions will reject orders.
- `trading_models.py` enums exist but actual order/cancel in `routers/trading.py` uses raw xtconstant ints (23/24).
