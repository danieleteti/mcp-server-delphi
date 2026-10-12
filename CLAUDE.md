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

## Tests

```bash
tests\build_all.bat   # builds testproject, clientproject, agentproject (Win32 Debug; set BDS to override the RAD Studio path)
tests\run_all.bat     # starts the test server, then runs every suite and propagates the first failure
```

Six suites run: the Python HTTP compliance suite, the Python stdio suite, the Python security suite, the Delphi `TMCPClient` suite over HTTP and over stdio, and the `TMCPOpenAIAgent` suite driven by an embedded fake LLM.

Last counts: HTTP 199, stdio 160, security 124, `TMCPClient` 21 (HTTP) and 21 (stdio), agent 32.

The security suite (`tests/test_mcp_security.py`) starts the test server itself, on port 8086, once per configuration. The configuration is chosen with flags read by `tests/testproject/TestFlagsU.pas` (`--auth-token`, `--jwt`, `--jwt-lax`, `--auth-elsewhere`, `--guard-path`, `--bridge-*`, ...).

The stdio suite has a subset for any stdio MCP server: `python tests/test_mcp_server_stdio.py --cmd "<server command>" --server-independent`. It runs the handshake, framing, error-code and list cases and skips every case that names a tool, resource or prompt of the library's own test server (70 cases against the test server, 34 against `tests/logorder/bin/LogOrderProbe.exe`). A case that names a tool, resource or prompt must stay out of that subset.

`tests/logorder/` is a probe program with two tools, one of them with a dot in its name, built by `build_all.bat`. It registers a provider unit before any logging unit; the stdio suite checks that registration (the dotted name included) writes nothing to stdout.

The agent suite additionally contains a **live provider suite** that talks to a real OpenAI-compatible endpoint. It is skipped unless a key is present, so the default run stays offline and free:

```bash
set OPENROUTER_API_KEY=sk-or-...
tests\run_all.bat
rem or, directly: MCPAgentTest.exe --api-key <key> [--llm-base-url <url>] [--model <id>]
```

It covers what a fake LLM cannot: that a real provider accepts the generated `inputSchema`, dispatches the tools, streams SSE into `OnContentDelta`, still reports usage on a streamed run, and reads a `TMCPDataSetFormat.Table` result correctly. Run it after touching tool descriptors, the agent loop or the tool-name generation - a fake server accepts payloads that Anthropic, OpenAI, Azure and Bedrock reject outright.

## Architecture

### Core Library (`Sources/`)

The library follows an **attribute-driven, RTTI-based discovery** pattern with DMVCFramework's `PublishObject` for JSON-RPC dispatch:

- **MVCFramework.MCP.Server.pas** — Contains `TMCPServer` (shared registry, created once at startup, scans providers via RTTI) and `TMCPEndpoint` (published object, created per request via `PublishObject` factory). MCP method names with `/` are stripped in `OnBeforeRoutingHook` (e.g. `tools/list` → `ToolsList`).
- **MVCFramework.MCP.Guard.pas** — `MCPGuard(TMCPGuardOptions.Create...)` returns an HTTP filter for the `/mcp` endpoint. Registered with `AEngine.UseHTTPFilter`, before `PublishObject` and before any classic middleware. For a request on the endpoint path it checks, in this order: bearer token (401 with `WWW-Authenticate: Bearer`; each token has a name, which becomes `LoggedUser.UserName`); when no token is configured and `AuthenticationHandledElsewhere` is not set, the `Host` header (403 unless `localhost`, `127.0.0.1`, `[::1]` or an `AllowedHosts` entry); `Origin`, when present (403 unless listed in `AllowedOrigins`); verb (405 with `Allow: POST, DELETE` unless the request is a POST or DELETE on the endpoint path itself, so `GET /mcp`, `GET /mcp/describe` and `OPTIONS` are refused). The path is compared with the router's normalisation, on the decoded and the raw form. A vetted request is marked in the context (`MCP_GUARD_MARK`; the value says whether the guard was built with `AuthenticationHandledElsewhere`). Building a guard sets `TMCPServer.GuardInstalled`; from then on the endpoint and `TMCPSessionController` refuse every request that carries no mark (403, and one `LogW` naming the request path and the likely cause), and, when the guard was built with `AuthenticationHandledElsewhere`, every vetted request that has no valid logged user (401 with `WWW-Authenticate: Bearer`). `BearerToken` refuses a value that is empty or has leading or trailing whitespace (the presented token is trimmed, so it could never match), and `EndpointPath` refuses `''` and `'/'` (they would guard the whole application); both raise `EMCPGuardException`. Without a token and without `AuthenticationHandledElsewhere` the guard logs a warning at startup.
- **MVCFramework.MCP.Attributes.pas** — Custom attributes: `MCPToolAttribute` and `MCPParamAttribute` (placed on parameters) for tools, `MCPResourceAttribute`, `MCPPromptAttribute`, `MCPPromptArgAttribute`. Parameter presence is expressed via `TMCPParamPresence = (Required, Optional)` (scoped enum, `{$SCOPEDENUMS ON}`) — the second argument of `[MCPParam]` and `[MCPPromptArg]`, defaulting to `Required` and `Optional` respectively.
- **MVCFramework.MCP.Session.pas** — Thread-safe in-memory session manager with 30-minute timeout using `TCriticalSection`.
- **MVCFramework.MCP.ToolProvider.pas / MVCFramework.MCP.ResourceProvider.pas / MVCFramework.MCP.PromptProvider.pas** — Base classes and result record types. Result types use factory methods (`TMCPToolResult.Text()`, `.Error()`, `.JSON()`, `.Image()`). `FromDataSet` takes an optional `TMCPDataSetFormat`: `Json` (default, one JSON object per row) or `Table` (pipe-separated, header written once). Prefer `Table` for anything a model reads — a tool result is re-sent on every later turn of the run, so repeating the field names on every row is paid for once per turn.
- **MVCFramework.MCP.Types.pas** — Protocol constants and capability records.

### Operational limits of the guard

- **Browser clients.** `OPTIONS` on the endpoint is refused (401, 403 or 405 depending on the configuration): a real browser preflight carries `Origin` and no `Authorization`, so it gets 401 when a token is configured, 403 when the origin is not listed and 405 otherwise. A cross-origin browser client therefore cannot pass its preflight: browser-based MCP clients are not supported in 0.9.0. `AllowedOrigins` exists to refuse cross-origin requests: a request with an `Origin` header that is not listed gets 403 (native clients send none).
- **`EndpointPath`.** It is the full routed path of the published object, engine path prefix included (`PublishObject(..., '/mcp')` under the prefix `/api` is `/api/mcp`). The default is `/mcp`. If the guard's path does not match, the guard vets nothing and the endpoint fails closed: a POST JSON-RPC call to the endpoint gets 403 and no method is dispatched, and `DELETE` on the session controller gets 403. What is not refused: `GET <path>`, `GET <path>/describe` and `GET <path>/proxy` of the JSON-RPC publisher do not go through the endpoint's hook. With a mismatched path, `GET /mcp` answers 200 with a JSON-RPC "Invalid Request" error, `/describe` answers 200 with the generated description of the published methods, and `/proxy` answers 500. No tool, resource or prompt runs on any of them. `TMCPSessionController` is routed on the fixed path `/mcp`: an application that publishes the endpoint elsewhere and points the guard there gets its session `DELETE` refused (403), not served.
- **Process-wide.** `GuardInstalled` is one flag on `TMCPServer.Instance`. Once one guard is built, every MCP endpoint in the process expects vetted requests.
- **Hosts.** The library's own suites run the guard on Indy Direct. On HTTP.sys and on the WebBroker console host the token (401 with `WWW-Authenticate`), verb (405) and `Origin` (403) rules have been run through the projects generated by the DMVCFramework wizard (`ideexpert/tests/test_generated_mcp.py` in the framework repository); the other cases of the security suite have not been run there.
- **JWT in front of `/mcp`.** Supported with the framework's classic JWT middleware, used instead of the bearer token: a valid JWT gives the provider `Caller.UserName` and `Caller.Roles`. The guard goes first, with `AuthenticationHandledElsewhere`; the middleware is added after it:

```pascal
AEngine.UseHTTPFilter(MCPGuard(TMCPGuardOptions.Create.AuthenticationHandledElsewhere));
AEngine.AddMiddleware(TMVCJWTAuthenticationMiddleware.Create(
  TMyAuthHandler.Create, LClaimsSetup, LSecret, '/login', LCheckedClaims, 300));
```

The middleware refuses a request (401) only if the application's authentication handler requires authentication for the class that serves the endpoint. The handler's `OnRequest(AContext, AControllerQualifiedClassName, AActionName, var AAuthenticationRequired)` receives the qualified class name of the matched controller; it must set `AAuthenticationRequired := True` for these two:

- `MVCFramework.JSONRPC.TMVCJSONRPCPublisher`: the published object, the `POST` on the endpoint.
- `MVCFramework.MCP.Server.TMCPSessionController`: the session `DELETE`.

A handler that returns `False` for them (or only requires authentication for classes it lists) leaves the middleware letting the request through unauthenticated. `AuthenticationHandledElsewhere` turns off the guard's `Host` check and its "unauthenticated" startup warning, so nothing else reports that. As a last line, a guard built with `AuthenticationHandledElsewhere` makes the endpoint and the session controller refuse (401, `WWW-Authenticate: Bearer`) any request that reaches them without a valid logged user, whatever the handler says. The same holds without any authentication middleware: `AuthenticationHandledElsewhere` with nothing that authenticates leaves the endpoint refusing every request (the `Origin` and verb rules still answer 403 and 405 first). The test server's `--jwt-lax` flag installs a handler that requires nothing, to exercise this.

### Caller identity

`TMCPCaller` (`MVCFramework.MCP.Types.pas`) has `Transport` (`http` or `stdio`), `UserName` and `Roles`. The request handler sets `Caller` on each per-call provider instance (tools, resources and prompts). On the stdio transport it holds the transport only (`stdio||` in the test server's `whoami`). Over HTTP the user and roles come from `Context.LoggedUser` (the guard's token name, or the JWT middleware's user and roles). The shared bridge provider does not get a `Caller`.

### REST-to-MCP bridge

`MVCFramework.MCP.Bridge.pas` turns the routes of a `TMVCEngine` into MCP tools: `TMCPServer.Instance.RegisterFromEngine(AEngine, ABaseURL[, AOptions])`. Each call to a tool is an HTTP request to `ABaseURL` made by the library.

- `TMCPBridgeOptions` narrows what is exposed. Applied in this order: `OnlyControllers([...])`, `ExcludeMethods([...])`, `ExcludePath(regex)`. `Header(name, value)` adds a header to every bridged call (an API key, for instance).
- `ExcludePath` is matched against the path built from the controller and action `MVCPath` attributes only. It does not include the engine's path prefix or a custom URL segment given at `AddController`: with the prefix `/api`, `.ExcludePath('^/api/admin/')` excludes nothing; write `'^/admin/'`.
- The bridge does not forward the identity of the MCP caller: every MCP caller acts on the API with the fixed `Header(...)` credential.
- The scanner keeps every verb of an action.
- Never exposed, whatever the options: the system controller, the JSON-RPC publisher (the MCP endpoint itself) and `TMCPSessionController`.
- A second registration for the same base URL is ignored (hosts that build one engine per worker call the configuration procedure more than once). The check, the scan and the registration run under one monitor on the server instance, so two threads registering together (WebBroker runs the configuration procedure on request threads) register once. The test server's `--bridge-concurrent N` flag registers from N threads at once.
- Bridged calls reach the API from loopback. A protection of the API based on the client address does not apply to MCP callers: the API sees the loopback address for all of them. `https` base URLs work only with a certificate the machine trusts.

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
- **Logs never touch stdout.** Registration no longer logs: `TMCPServer` writes one summary of the registry when a transport starts (the first HTTP request, or `Run` of the stdio transport; `AddSummaryLine` adds lines to it), so the position of provider units in the `uses` clause does not matter. Warnings found while registering (a tool name outside `[A-Za-z0-9_-]`) are collected and written by the same summary, at warning level; `AddSummaryLine` and the summary are safe against each other across threads. The console logger still has to be off in stdio mode: `TransportConf` and `StdioOnly` are still the way to switch it off. Stdio-only servers include `MVCFramework.MCP.StdioOnly`, which unconditionally disables the console logger; dual-transport servers use `MVCFramework.MCP.TransportConf`, which leaves it on for HTTP mode. A dual-transport server whose default is stdio calls `MCPDefaultTransportStdio` (same unit) as the first statement of its `.dpr`: from then on `MCPTransportIsStdio` is True unless the command line says `--transport http`, and a start with no `--transport` at all writes one line on stderr saying so. Diagnostics go to stderr/file via LoggerPro.

stdio does not use the session manager — `Run` calls `HandleRequest` directly, so `Mcp-Session-Id` and the whole session/timeout machinery are HTTP-only.

**What a provider may rely on in stdio:** nothing the HTTP pipeline sets up — no engine, no middleware, no filter, no request context. A provider that needs a database connection, or anything a middleware gives it over HTTP, acquires it itself. `Caller` is available: transport `stdio`, no user, no roles.

### Test Application (`tests/testproject/`)

Same wizard-style layout as `sample/` (BootConfigU + EngineConfigU + slim .dpr).

- **MCPServerUnitTest.dpr** — Test server with comprehensive providers.
- **BootConfigU.pas / EngineConfigU.pas** — Boot + engine wiring (conformance providers registered via unit `initialization` sections).
- **MCPTestToolsU.pas** — 21 tools (36 in `tools/list` with the conformance and bridge providers) exercising all `TMCPToolResult` factory methods and parameter types, including both `FromDataSet` wire formats (`get_dataset_json` / `get_dataset_table`) and `whoami`, which returns the caller as `transport|user|roles`.
- **MCPTestResourcesU.pas** — 6 resources (text, blob, two templated, and `caller://whoami`, which returns the caller like `whoami`).
- **MCPTestPromptsU.pas** — 4 prompts with required/optional arguments (`whoami` returns the caller).
- **MCPConformanceProvidersU.pas** — Conformance providers registering tools, resources, and prompts.
- **TestFlagsU.pas / TestAuthHandlerU.pas** — Command-line flags that switch the guard, the bridge options and the JWT middleware on, and the authentication handler used by `--jwt`.

## Configuration

Environment variables in `Sample/bin/.env`: `SERVER_PORT`, `https.enabled`, `https.cert.*`, `dmvc.*` settings.

## Conventions

- Delphi naming: `T`-prefixed classes, `F`-prefixed fields, `I`-prefixed interfaces
- Session header: `Mcp-Session-Id`
- Logging via `MVCFramework.Logger` (`LogI`, `LogE`, `LogW`)
- Optional JSON-RPC params use `[MVCJSONRPCOptional]` attribute on method parameters
