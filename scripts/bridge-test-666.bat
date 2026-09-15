@echo off
cd /d "%~dp0.."
set APP_MODE=prod
set APP_PORT=8003
set GRPC_PORT=50053
set APP_SERVERS=rest
set APP_LOCAL_CONFIG=config.local.666.yml
set PYTHONPATH=C:\bridge-client\bridge\src;C:\bridge-client
.venv\Scripts\python.exe run.py > logs\bridge-test-666.log 2>&1
