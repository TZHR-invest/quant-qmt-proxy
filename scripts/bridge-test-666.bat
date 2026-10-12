@echo off
cd /d "%~dp0.."
rem REHEARSAL REPLICA launcher -- NOT a production service.  Starts a copy of the bridge
rem for the 666 account so a test can hit a live-shaped stack without touching 8001/8002.
rem Ports, as of 2026-09-28: 8003 / 50053 are now the THIRD account's PRODUCTION ports
rem [2986 = G:\qmt2, service QMTProxy-2986] so this replica moved to 8007 / 50057.
rem Keeping 8003 here would fight the live service for the port, and a "-Port 8003"
rem handed to a test tool would silently land on production 2986 instead of the replica.
rem ASCII comments on purpose: cmd.exe decodes .bat with the OEM code page [GBK here],
rem so UTF-8 Chinese in a rem line would only show up as mojibake.
set APP_MODE=prod
set APP_PORT=8007
set GRPC_PORT=50057
set APP_SERVERS=rest
set APP_LOCAL_CONFIG=config.local.666.yml
set PYTHONPATH=C:\bridge-client\bridge\src;C:\bridge-client
.venv\Scripts\python.exe run.py > logs\bridge-test-666.log 2>&1
