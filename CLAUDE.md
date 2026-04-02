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
dcc32.exe Sample/MCPServerSample.dpr -ESample/bin

# Compile the test server
dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin
```

The project files can also be opened and built directly in the Delphi IDE.

## Architecture

### Core Library (`Sources/`)

The library follows an **attribute-driven, RTTI-based discovery** pattern with DMVCFramework's `PublishObject` for JSON-RPC dispatch:

- **MVCFramework.MCP.Server.pas** — Contains `TMCPServer` (shared registry, created once at startup, scans providers via RTTI) and `TMCPEndpoint` (published object, created per request via `PublishObject` factory). MCP method names with `/` are stripped in `OnBeforeRoutingHook` (e.g. `tools/list` → `ToolsList`).
- **MVCFramework.MCP.Attributes.pas** — Custom attributes: `MCPToolAttribute` and `MCPParamAttribute` (placed on parameters) for tools, `MCPResourceAttribute`, `MCPPromptAttribute`, `MCPPromptArgAttribute`.
- **MVCFramework.MCP.Session.pas** — Thread-safe in-memory session manager with 30-minute timeout using `TCriticalSection`.
- **MVCFramework.MCP.ToolProvider.pas / MVCFramework.MCP.ResourceProvider.pas / MVCFramework.MCP.PromptProvider.pas** — Base classes and result record types. Result types use factory methods (`TMCPToolResult.Text()`, `.Error()`, `.JSON()`, `.Image()`).
- **MVCFramework.MCP.Types.pas** — Protocol constants and capability records.

### Provider Pattern

To add MCP capabilities, create a class extending `TMCPToolProvider`, decorate methods with `[MCPTool]` and parameters with `[MCPParam]`, and register via `TMCPServer.RegisterToolProvider()`. See `Sample/MyToolsU.pas` for examples.

### Sample Application (`Sample/`)

- **MCPServerSample.dpr** — Console app entry point.
- **WebModuleU.pas** — Bootstraps `TMVCEngine`, publishes MCP endpoint via `PublishObject`.
- **MyToolsU.pas** — Example tools: `reverse_string`, `string_length`, `echo`.

### Test Application (`tests/testproject/`)

- **MCPServerUnitTest.dpr** — Test server with comprehensive providers.
- **MCPTestToolsU.pas** — 18 tools exercising all `TMCPToolResult` factory methods and parameter types.
- **MCPTestResourcesU.pas** — 3 resources (text and blob).
- **MCPTestPromptsU.pas** — 3 prompts with required/optional arguments.

## Configuration

Environment variables in `Sample/bin/.env`: `SERVER_PORT`, `https.enabled`, `https.cert.*`, `dmvc.*` settings.

## Conventions

- Delphi naming: `T`-prefixed classes, `F`-prefixed fields, `I`-prefixed interfaces
- Session header: `Mcp-Session-Id`
- Logging via `MVCFramework.Logger` (`LogI`, `LogE`, `LogW`)
- Optional JSON-RPC params use `[MVCJSONRPCOptional]` attribute on method parameters
