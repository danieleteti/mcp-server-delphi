# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MCP (Model Context Protocol) Server for DMVCFramework, using the idiomatic `PublishObject` JSON-RPC pattern. Allows DMVCFramework applications to expose MCP tools, resources, and prompts via the `/mcp` endpoint.

- **Language:** Object Pascal (Delphi 11+)
- **Protocol:** MCP version 2025-03-26
- **License:** Apache 2.0

## Build

```bash
# Compile the sample application (requires Delphi compiler)
dcc32.exe sample/MCPServerSample.dpr -Esample/bin

# Compile the test server
dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin
```

The project files can also be opened and built directly in the Delphi IDE.

## Architecture

### Core Library (`Sources/`)

The library follows an **attribute-driven, RTTI-based discovery** pattern with DMVCFramework's `PublishObject` for JSON-RPC dispatch:

- **MVCFramework.MCP.Server.pas** — Contains `TMCPServer` (shared registry, created once at startup, scans providers via RTTI) and `TMCPEndpoint` (published object, created per request via `PublishObject` factory). MCP method names with `/` are stripped in `OnBeforeRoutingHook` (e.g. `tools/list` → `ToolsList`).
- **MVCFramework.MCP.Attributes.pas** — Custom attributes: `MCPToolAttribute` and `MCPParamAttribute` (placed on parameters) for tools, `MCPResourceAttribute`, `MCPPromptAttribute`, `MCPPromptArgAttribute`. Parameter presence is expressed via `TMCPParamPresence = (Required, Optional)` (scoped enum, `{$SCOPEDENUMS ON}`) — the second argument of `[MCPParam]` and `[MCPPromptArg]`, defaulting to `Required` and `Optional` respectively.
- **MVCFramework.MCP.Session.pas** — Thread-safe in-memory session manager with 30-minute timeout using `TCriticalSection`.
- **MVCFramework.MCP.ToolProvider.pas / MVCFramework.MCP.ResourceProvider.pas / MVCFramework.MCP.PromptProvider.pas** — Base classes and result record types. Result types use factory methods (`TMCPToolResult.Text()`, `.Error()`, `.JSON()`, `.Image()`).
- **MVCFramework.MCP.Types.pas** — Protocol constants and capability records.

### Provider Pattern

To add MCP capabilities, create a class extending `TMCPToolProvider`, decorate methods with `[MCPTool]` and parameters with `[MCPParam]`, and register via `TMCPServer.RegisterToolProvider()`. See `Sample/MyToolsU.pas` for examples.

### Sample Application (`sample/`)

Organized like a DMVCFramework wizard-generated project (BootConfigU + EngineConfigU + slim .dpr):

- **MCPServerSample.dpr** — Console entry point. Calls `Boot`, then runs HTTP (Indy Direct) or stdio transport based on `--transport`.
- **BootConfigU.pas** — `Boot` configures dotEnv + LoggerPro + profiler. Picks `loggerpro.json` (console + file) or `loggerpro.stdio.json` (file only) via `MCPTransportIsStdio`.
- **EngineConfigU.pas** — `ConfigureEngine` adds `TMCPSessionController` and publishes the MCP endpoint at `/mcp` via `PublishObject`.
- **MyToolsU.pas** — Example tools: `reverse_string`, `string_length`, `echo`.
- **bin/loggerpro.json, bin/loggerpro.stdio.json** — LoggerPro appender configs.

The engine is built with `TMVCEngine.Create(AConfigAction)` then wrapped by `TMVCServerFactory.CreateIndyDirect`. HTTPS is opt-in through `TaurusTLSIndyConfigurator`. No WebBroker / TWebModule.

### HTTP transport

All HTTP/HTTPS samples and the test server run on DMVCFramework's Indy Direct backend. There is no `TWebModule` / `Web.WebBroker` / `TIdHTTPWebBrokerBridge` in the uses chain: the engine owns the request pipeline. To enable HTTPS on a server, add `MVCFramework.Server.HTTPS.TaurusTLS` to the uses clause, then:

```pascal
LServer.HTTPSConfigurator := TaurusTLSIndyConfigurator();
LServer.UseHTTPS := True;
LServer.CertFile := '...';
LServer.KeyFile  := '...';
LServer.CertPassword := '...';
LServer.Listen(APort);
```

### stdio transport

`MVCFramework.MCP.Stdio.pas` (`TMCPStdioTransport`) is the line-delimited JSON-RPC transport used when an MCP client (Claude Desktop, Claude Code, MCP Inspector) launches the server as a child process. `Run` blocks reading stdin until EOF, then exits — that is the correct lifecycle, not a bug.

Two invariants keep it stable, and both must be preserved:

- **stdout is UTF-8, LF-framed, and reserved for JSON-RPC only.** `Run` calls `SetTextCodePage(Input/Output, CP_UTF8)` at startup: without it, Windows text-mode `ReadLn`/`WriteLn` use the console/ANSI code page, so any non-ASCII byte (accented text, `€`, emoji, CJK) is emitted as e.g. Windows-1252 and the UTF-8 client rejects it with an invalid-continuation-byte error. All-ASCII payloads still work, so the defect is latent — regression-guarded by `test_utf8_roundtrip` in `tests/test_mcp_server_stdio.py`. All responses go through the private `WriteResponse`, which appends a single LF (`#10`) rather than `WriteLn`'s platform CRLF. Never `Write`/`WriteLn` to stdout from tool/provider code, and let no unhandled exception print there — a single stray byte breaks the client.
- **Logs never touch stdout.** stdio-only servers include `MVCFramework.MCP.StdioOnly` (before any provider unit) to unconditionally disable the console logger; diagnostics go to stderr/file via LoggerPro. Dual-transport servers use `MVCFramework.MCP.TransportConf` instead, which leaves the console logger on for HTTP mode.

stdio does not use the session manager — `Run` calls `HandleRequest` directly, so `Mcp-Session-Id` and the whole session/timeout machinery are HTTP-only.

### Test Application (`tests/testproject/`)

Same wizard-style layout as `sample/` (BootConfigU + EngineConfigU + slim .dpr).

- **MCPServerUnitTest.dpr** — Test server with comprehensive providers.
- **BootConfigU.pas / EngineConfigU.pas** — Boot + engine wiring (conformance providers registered via unit `initialization` sections).
- **MCPTestToolsU.pas** — 18 tools exercising all `TMCPToolResult` factory methods and parameter types.
- **MCPTestResourcesU.pas** — 3 resources (text and blob).
- **MCPTestPromptsU.pas** — 3 prompts with required/optional arguments.
- **MCPConformanceProvidersU.pas** — Conformance providers registering tools, resources, and prompts.

## Configuration

Environment variables in `Sample/bin/.env`: `SERVER_PORT`, `https.enabled`, `https.cert.*`, `dmvc.*` settings.

## Conventions

- Delphi naming: `T`-prefixed classes, `F`-prefixed fields, `I`-prefixed interfaces
- Session header: `Mcp-Session-Id`
- Logging via `MVCFramework.Logger` (`LogI`, `LogE`, `LogW`)
- Optional JSON-RPC params use `[MVCJSONRPCOptional]` attribute on method parameters
