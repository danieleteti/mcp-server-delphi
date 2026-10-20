@echo off
rem ----------------------------------------------------------------------
rem Orchestrates the full test pipeline:
rem   1. Start the test MCP server on HTTP (tests/testproject/bin/MCPServerUnitTest.exe)
rem   2. Run the Python HTTP compliance suite (test_mcp_server.py)
rem   3. Run the Python stdio compliance suite (test_mcp_server_stdio.py) -
rem      it spawns its own copy of the server in stdio mode
rem   4. Run the Delphi TMCPClient compliance suite over HTTP
rem   5. Run the same Delphi TMCPClient suite over stdio (the client spawns
rem      the same testproject exe as a subprocess in stdio mode)
rem   6. Run the Delphi TMCPOpenAIAgent compliance suite (with its own
rem      embedded fake LLM on port 9091)
rem   7. Stop the test MCP server
rem
rem Exit code: 0 if every suite passes, otherwise the first failed exit
rem code propagates.
rem ----------------------------------------------------------------------

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

echo [1/6] Starting MCP test server on :%MCP_PORT%...
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
echo [2/6] Python compliance suite, HTTP (test_mcp_server.py)...
python "%TESTS_DIR%test_mcp_server.py" --url %MCP_URL%
SET PY_HTTP_EXIT=%ERRORLEVEL%

echo.
echo [3/6] Python compliance suite, stdio (test_mcp_server_stdio.py)...
python "%TESTS_DIR%test_mcp_server_stdio.py" --cmd "\"%TESTS_DIR%testproject\bin\MCPServerUnitTest.exe\" --transport stdio"
SET PY_STDIO_EXIT=%ERRORLEVEL%

echo.
echo [security] Python security and bridge-filter suite...
python "%TESTS_DIR%test_mcp_security.py"
SET PY_SEC_EXIT=%ERRORLEVEL%

echo.
echo [4/6] Delphi TMCPClient compliance suite (HTTP)...
"%TESTS_DIR%clientproject\bin\MCPClientTest.exe" --url %MCP_URL%
SET CLIENT_HTTP_EXIT=%ERRORLEVEL%

echo.
echo [5/6] Delphi TMCPClient compliance suite (stdio)...
"%TESTS_DIR%clientproject\bin\MCPClientTest.exe" --stdio-cmd "%TESTS_DIR%testproject\bin\MCPServerUnitTest.exe --transport stdio"
SET CLIENT_STDIO_EXIT=%ERRORLEVEL%

echo.
echo [6/6] Delphi TMCPOpenAIAgent compliance suite...
"%TESTS_DIR%agentproject\bin\MCPAgentTest.exe" --mcp-url %MCP_URL%
SET AGENT_EXIT=%ERRORLEVEL%

echo.
echo [7/7] 2026-07-28 era: Python suite (HTTP + stdio) and Delphi client (modern, auto)...
python "%TESTS_DIR%test_mcp_modern.py" --url %MCP_URL% --cmd "\"%TESTS_DIR%testproject\bin\MCPServerUnitTest.exe\" --transport stdio"
SET MODERN_PY_EXIT=%ERRORLEVEL%
"%TESTS_DIR%clientproject\bin\MCPClientTest.exe" --url %MCP_URL% --era modern
SET MODERN_HTTP_EXIT=%ERRORLEVEL%
"%TESTS_DIR%clientproject\bin\MCPClientTest.exe" --stdio-cmd "%TESTS_DIR%testproject\bin\MCPServerUnitTest.exe --transport stdio" --era modern
SET MODERN_STDIO_EXIT=%ERRORLEVEL%
"%TESTS_DIR%clientproject\bin\MCPClientTest.exe" --url %MCP_URL% --era auto
SET AUTO_HTTP_EXIT=%ERRORLEVEL%
"%TESTS_DIR%clientproject\bin\MCPClientTest.exe" --stdio-cmd "%TESTS_DIR%testproject\bin\MCPServerUnitTest.exe --transport stdio" --era auto
SET AUTO_STDIO_EXIT=%ERRORLEVEL%

echo.
echo Stopping test server...
taskkill /F /IM MCPServerUnitTest.exe >NUL 2>&1

echo.
echo ===========================================================
echo Python suite (HTTP)         : exit %PY_HTTP_EXIT%
echo Python suite (stdio)        : exit %PY_STDIO_EXIT%
echo Python suite (security)     : exit %PY_SEC_EXIT%
echo TMCPClient suite (HTTP)     : exit %CLIENT_HTTP_EXIT%
echo TMCPClient suite (stdio)    : exit %CLIENT_STDIO_EXIT%
echo TMCPOpenAIAgent suite       : exit %AGENT_EXIT%
echo 2026-07-28 Python suite    : exit %MODERN_PY_EXIT%
echo TMCPClient modern (HTTP)    : exit %MODERN_HTTP_EXIT%
echo TMCPClient modern (stdio)   : exit %MODERN_STDIO_EXIT%
echo TMCPClient auto (HTTP)      : exit %AUTO_HTTP_EXIT%
echo TMCPClient auto (stdio)     : exit %AUTO_STDIO_EXIT%
echo ===========================================================

if not "%PY_HTTP_EXIT%"=="0"     exit /b %PY_HTTP_EXIT%
if not "%PY_STDIO_EXIT%"=="0"    exit /b %PY_STDIO_EXIT%
if not "%PY_SEC_EXIT%"=="0"      exit /b %PY_SEC_EXIT%
if not "%CLIENT_HTTP_EXIT%"=="0" exit /b %CLIENT_HTTP_EXIT%
if not "%CLIENT_STDIO_EXIT%"=="0" exit /b %CLIENT_STDIO_EXIT%
if not "%AGENT_EXIT%"=="0"       exit /b %AGENT_EXIT%
if not "%MODERN_PY_EXIT%"=="0"    exit /b %MODERN_PY_EXIT%
if not "%MODERN_HTTP_EXIT%"=="0"  exit /b %MODERN_HTTP_EXIT%
if not "%MODERN_STDIO_EXIT%"=="0" exit /b %MODERN_STDIO_EXIT%
if not "%AUTO_HTTP_EXIT%"=="0"    exit /b %AUTO_HTTP_EXIT%
if not "%AUTO_STDIO_EXIT%"=="0"   exit /b %AUTO_STDIO_EXIT%
echo ALL SUITES PASSED.
endlocal
exit /b 0
