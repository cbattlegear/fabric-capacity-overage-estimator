@echo off
if not "%~1"=="account" exit /b 9
if not "%~2"=="get-access-token" exit /b 9
if not "%~3"=="--resource" exit /b 9
if not "%~4"=="https://analysis.windows.net/powerbi/api" exit /b 9
if not "%~5"=="--output" exit /b 9
if not "%~6"=="json" exit /b 9
if not "%~7"=="--only-show-errors" exit /b 9
echo {"accessToken":"offline-cli-token"}
exit /b 0
