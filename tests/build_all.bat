@echo off
rem ──────────────────────────────────────────────────────────────────────
rem Builds all three test projects (Win32 Debug):
rem   - tests/testproject  - the test MCP server
rem   - tests/clientproject - TMCPClient compliance test
rem   - tests/agentproject  - TMCPOpenAIAgent compliance test (with fake LLM)
rem ──────────────────────────────────────────────────────────────────────

setlocal
SET BDS=C:\Program Files (x86)\Embarcadero\Studio\37.0
SET FrameworkDir=C:\Windows\Microsoft.NET\Framework
SET FrameworkVersion=v4.0.30319
SET PATH=%FrameworkDir%\%FrameworkVersion%;%BDS%\bin;%PATH%
SET TESTS_DIR=%~dp0

echo === testproject (Win32) ===
msbuild "%TESTS_DIR%testproject\MCPServerUnitTest.dproj" /p:Config=Debug /p:Platform=Win32 /t:Build /v:minimal /nologo
if errorlevel 1 exit /b 1

echo.
echo === clientproject (Win32) ===
msbuild "%TESTS_DIR%clientproject\MCPClientTest.dproj" /p:Config=Debug /p:Platform=Win32 /t:Build /v:minimal /nologo
if errorlevel 1 exit /b 1

echo.
echo === agentproject (Win32) ===
msbuild "%TESTS_DIR%agentproject\MCPAgentTest.dproj" /p:Config=Debug /p:Platform=Win32 /t:Build /v:minimal /nologo
if errorlevel 1 exit /b 1

echo.
echo === ALL TEST PROJECTS BUILT ===
endlocal
