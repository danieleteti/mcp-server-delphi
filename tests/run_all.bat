@echo off
rem ──────────────────────────────────────────────────────────────────────
rem Orchestrates the full test pipeline:
rem   1. Start the test MCP server (tests/testproject/bin/MCPServerUnitTest.exe)
rem   2. Run the Python compliance suite (test_mcp_server.py)
rem   3. Run the Delphi TMCPClient compliance suite (clientproject)
rem   4. Run the Delphi TMCPOpenAIAgent compliance suite (agentproject, with
rem      its own embedded fake LLM on port 9091)
rem   5. Stop the test MCP server
rem
rem Exit code: 0 if every suite passes, otherwise the first failed exit
rem code propagates.
rem ──────────────────────────────────────────────────────────────────────

setlocal
SET TESTS_DIR=%~dp0
SET MCP_PORT=8080
SET MCP_URL=http://localhost:%MCP_PORT%/mcp

if not exist "%TESTS_DIR%testproject\bin\MCPServerUnitTest.exe" (
  echo ERROR: testproject not built. Run build_all.bat first.
  exit /b 1
)
if not exist "%TESTS_DIR%clientproject\bin\MCPClientTest.exe" (
  echo ERROR: clientproject not built. Run build_all.bat first.
  exit /b 1
)
if not exist "%TESTS_DIR%agentproject\bin\MCPAgentTest.exe" (
  echo ERROR: agentproject not built. Run build_all.bat first.
  exit /b 1
)

echo [1/4] Starting MCP test server on :%MCP_PORT%...
start "MCPServerUnitTest" /B "%TESTS_DIR%testproject\bin\MCPServerUnitTest.exe" --transport http
rem Wait until the server answers ping (timeout 30s).
set /a WAITED=0
:wait_server
curl -sf -o NUL -X POST "%MCP_URL%" -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":0}" >NUL 2>&1
if not errorlevel 1 goto server_up
set /a WAITED=%WAITED%+1
if %WAITED% GEQ 30 (
  echo ERROR: server did not start within 30s
  taskkill /F /IM MCPServerUnitTest.exe >NUL 2>&1
  exit /b 1
)
timeout /T 1 /NOBREAK >NUL 2>&1
goto wait_server
:server_up
echo Server up.

echo.
echo [2/4] Python compliance suite (test_mcp_server.py)...
python "%TESTS_DIR%test_mcp_server.py" --url %MCP_URL%
SET PY_EXIT=%ERRORLEVEL%

echo.
echo [3/4] Delphi TMCPClient compliance suite...
"%TESTS_DIR%clientproject\bin\MCPClientTest.exe" --url %MCP_URL%
SET CLIENT_EXIT=%ERRORLEVEL%

echo.
echo [4/4] Delphi TMCPOpenAIAgent compliance suite...
"%TESTS_DIR%agentproject\bin\MCPAgentTest.exe" --mcp-url %MCP_URL%
SET AGENT_EXIT=%ERRORLEVEL%

echo.
echo Stopping test server...
taskkill /F /IM MCPServerUnitTest.exe >NUL 2>&1

echo.
echo ===========================================================
echo Python compliance suite : exit %PY_EXIT%
echo TMCPClient suite        : exit %CLIENT_EXIT%
echo TMCPOpenAIAgent suite   : exit %AGENT_EXIT%
echo ===========================================================

if not "%PY_EXIT%"=="0"     exit /b %PY_EXIT%
if not "%CLIENT_EXIT%"=="0" exit /b %CLIENT_EXIT%
if not "%AGENT_EXIT%"=="0"  exit /b %AGENT_EXIT%
echo ALL SUITES PASSED.
endlocal
exit /b 0
