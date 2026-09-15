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

## Production operations (this machine)

**Proxy services are NSSM Windows services** — do NOT start them by running
`start-prod-*.bat` or `sc start` directly (they conflict with nssm and can
start before QMT is logged in).

- `QMTProxy-020` (REST 8001 / gRPC 50051, account 020100053835, G:\qmt)
- `QMTProxy-666` (REST 8002 / gRPC 50052, account 666810082889, G:\qmt1)

Restart (admin PowerShell; waits for both MiniQMT trading channels first):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\restart-proxy.ps1 -WaitMinutes 3
```

Scheduled tasks (created at logon, SYSTEM/Interactive):

- `QMT-AutoLogin` (+30s, wbaif): clicks the MiniQMT login buttons via `scripts\qmt_auto_login.ps1` (credentials/captcha are pre-filled; skips already-logged-in windows).
- `QMT-Proxy-AutoStart` (+60s, SYSTEM): runs `restart-proxy.ps1 -WaitMinutes 15`, waits for QMT readiness (max 15 min) then starts both services.

Boot flow: QMT auto-starts via HKCU Run → QMT-AutoLogin clicks login → QMT-Proxy-AutoStart starts proxy services. MiniQMT has **no auto-login option**; it relies on the click script. After changing the trading password, log in manually once to refresh saved credentials.

Self-healing: nssm restarts a crashed proxy process after 5s. Circuit breaker in `trading_session_manager.py` (3 consecutive connect failures → 60s cooldown) prevents xtquant SDK writer exhaustion when QMT is down. QMT itself is **not** auto-restarted if it crashes mid-day — restart it manually and re-run `scripts\qmt_auto_login.ps1`.

### Starting / restarting QMT (2026-09-14)

On this broker build `XtItClient.exe` is a **lite-mode launcher**, not a resident client:
it logs in, writes `bin.x64\linkMini`, kills any running `XtMiniQmt.exe` that is not its own
child, spawns its own mini (already logged in), then exits normally.

Use it as a launcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\qmt-start-via-bigqmt.ps1 `
    -QmtDir "G:\qmt1" -Account "666810082889" -StopService "QMTProxy-666"
```

Verified 3x (~32 s, 2026-09-14): stops the proxy service, clears leftover launchers, starts
the launcher, waits for the new mini and its auto-login, probes the **trading channel** with
`qmt_ready_check.py`, then restarts the service. Exit code 0 = ready.

**Never start `XtItClient.exe` while the instance is live** -- it kills the production mini
(2026-09-14: 666 trading channel was down for 3 minutes).

**After any QMT-client experiment**, always: `taskkill /F /IM XtItClient.exe` (leftover
launchers never exit and then kill each other's mini, wedging the next start -- observed
4 leftovers causing a 180 s timeout and a 5 min outage) and delete `bin.x64\linkQmt` /
`linkMini` if present. Then verify the **trading channel**
(`POST /api/v1/trading/sessions` returning 200), not just a quote probe.

**NEVER use a `link*` wildcard when cleaning these up.** On Windows it also matches
`LinkageTrade.dll` (1 MB, required by the full client) and deletes it silently; after that
`XtItClient.exe` dies with "cannot find LinkageTrade.dll" and the login window never appears
(measured 2026-09-14). Use the explicit names only.
Probe script: `python scripts\qmt_ready_check.py <userdata_path> <account_id>` exits 0 when the trading channel is ready.

## Key gotchas

- **Python 3.10–3.13 required** (not 3.7, not 3.9).
- **API key** goes in `Authorization: Bearer` header, **not** `X-API-Key`.
- xtdata connect runs async in background thread; initial queries may return empty.
- Before dev/prod, create `config.local.yml` with `qmt_userdata_path` (MiniQMT: `userdata_mini`, QMT: `userdata`) and registered accounts.
- `enable_prod_orders: false` by default; prod sessions will reject orders.
- `trading_models.py` enums exist but actual order/cancel in `routers/trading.py` uses raw xtconstant ints (23/24).
- **Never** run `start-prod-*.bat` / `stop-all.bat` / `sc start QMTProxy-*` manually — use `scripts\restart-proxy.ps1` (admin) instead.
