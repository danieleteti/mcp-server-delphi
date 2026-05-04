# MCP Bridge — Design Spec
**Date:** 2026-05-04  
**Status:** Approved

## Overview

`MCPBridge` is a bootstrap + code-generation feature for `mcp-server-delphi`. It lets a DMVCFramework application expose its existing REST endpoints as MCP tools in one line of code, then generate curated `TMCPToolProvider` units ready for production refinement.

**Intended lifecycle:**
```
RegisterFromEngine()     →   test with real LLM   →   GenerateProviderUnit()   →   curate & compile
     (1 line)                (minutes/hours)           (1 line, run once)           (real work)
```

**Not intended for production.** Auto-converted REST APIs deliver significantly worse LLM performance than hand-curated MCP servers (ref: [Stop Converting Your REST APIs to MCP](https://jlowin.dev/blog/stop-converting-rest-apis-to-mcp)). This feature is a prototyping and scaffolding tool, not a permanent solution.

---

## Goals

1. **Discovery** — RTTI scan of a `TMVCEngine`: controllers, actions, paths, HTTP methods, doc, params.
2. **Bootstrap proxy** — `RegisterFromEngine(AEngine, ABaseURL)`: runtime tool provider that proxies HTTP calls to the running server.
3. **Code generator** — `GenerateProviderUnit(AOutputPath)`: emits one `.pas` file per controller with `TMCPToolProvider` subclasses ready to refine.
4. **Zero impact on existing code** — all new functionality lives in one new file: `MVCFramework.MCP.Bridge.pas`.

---

## Architecture

### New file

```
sources/MVCFramework.MCP.Bridge.pas
```

All components live here. No existing source files are modified except two backwards-compatible virtual method additions to `TMCPToolProvider` (see Integration section).

### Component map

```
TMVCEngine (existing)
      │
      ▼
TMCPEngineScanner                ← RTTI discovery: controller → action → path/method/params
      │
      ▼
TMCPBridgeRouteInfo[]            ← internal record: one entry per discoverable action
      │
      ├─────────────────────────────────────┐
      ▼                                     ▼
TMCPBridgeProvider              TMCPBridgeCodeGen
(runtime HTTP proxy)            (Pascal code emitter)
      │                                     │
      ▼                                     ▼
TMCPServer registry              one .pas file per controller
(tools/list, tools/call)
```

### Public API

Exposed via a class helper on `TMCPServer` — no changes to `MVCFramework.MCP.Server.pas`:

```pascal
// in MVCFramework.MCP.Bridge.pas
TMCPServerBridgeHelper = class helper for TMCPServer
  procedure RegisterFromEngine(AEngine: TMVCEngine; const ABaseURL: string);
  procedure GenerateProviderUnit(const AOutputPath: string);
end;
```

**Usage (EngineConfigU.pas):**
```pascal
TMCPServer.Instance.RegisterFromEngine(AEngine, 'http://localhost:8080');
```

**Usage (one-shot generation):**
```pascal
TMCPServer.Instance.GenerateProviderUnit('output/');
```

---

## Section 1: Discovery (`TMCPEngineScanner`)

### What is scanned

```
TMVCEngine.Controllers[]
    └── per TMVCControllerRoutingInfo
            ├── controller class → [MVCPath] (base path)
            └── per public method
                    ├── [MVCHTTPMethod]  → present? it is an action
                    ├── [MVCPath]        → relative path (combined with base)
                    ├── [MVCDoc]         → tool description (empty string if absent)
                    └── per Delphi parameter
                            ├── [MVCFromPath(name)]        → MCP param, required=true
                            ├── [MVCFromQuery(name, req)]  → MCP param, required=flag
                            ├── [MVCFromBody]              → MCP param "body": string JSON
                            ├── [MVCFromHeader]            → SKIP
                            └── [MVCFromCookie]            → SKIP
```

Parameters without any `MVCFrom*` attribute are skipped; the generated code includes a `// TODO: parameter 'X' has no MVCFrom* attribute — add manually` comment.

### `TMCPBridgeRouteInfo` record

| Field | Source |
|---|---|
| `ToolName` | derived from HTTP method + path (see naming rules) |
| `Description` | `[MVCDoc]` on the method, empty string if absent |
| `HTTPMethod` | `[MVCHTTPMethod]` |
| `PathTemplate` | controller `[MVCPath]` + action `[MVCPath]` |
| `Params[]` | `MVCFrom*` attributes on method parameters |

### Tool name generation

Rule: `lowercase(HTTPMethod) + '_' + path_to_snake_case`

Path transformation:
- Remove leading `/`
- Replace `/` with `_`
- Literal path segments stay as-is
- `{var}` placeholder → `by_var` (distinguishes from literal segment named `var`)
- Placeholder name converted from camelCase to snake_case: `customerId` → `customer_id`

Examples:

| HTTP method | Path | Tool name |
|---|---|---|
| GET | `/customers` | `get_customers` |
| GET | `/customers/{id}` | `get_customers_by_id` |
| GET | `/customers/{customerId}` | `get_customers_by_customer_id` |
| POST | `/customers` | `post_customers` |
| PUT | `/customers/{id}` | `put_customers_by_id` |
| DELETE | `/customers/{id}` | `delete_customers_by_id` |
| GET | `/orders/{orderId}/items/{itemId}` | `get_orders_by_order_id_items_by_item_id` |

### Uniqueness enforcement

1. First choice: generated name as above.
2. On collision: prefix with controller class name in snake_case (`TCustomersController` → `customers_`).
3. Still collision: raise `EMCPBridgeException` at registration time — fail fast with both conflicting methods named in the message.

### Delphi type → JSON Schema mapping

| Delphi type | JSON Schema |
|---|---|
| `Integer`, `Int64` | `"integer"` |
| `Double`, `Single`, `Extended` | `"number"` |
| `Boolean` | `"boolean"` |
| `string` | `"string"` |
| anything else | `"string"` (fallback, comment in generated code) |

---

## Section 2: Bootstrap Proxy (`TMCPBridgeProvider`)

### Why HTTP and not direct in-process call

DMVCFramework authentication and other middleware runs at the HTTP pipeline level. A direct RTTI call to the controller method bypasses all middleware — auth, rate limiting, request transformation — creating a security hole. HTTP on localhost is the correct approach: it runs the full pipeline, adds <1ms overhead (irrelevant for LLM tool calls), and matches how FastMCP handles the same problem.

### Prototype mode marker

`RegisterFromEngine` appends `[bootstrap proxy — not for production]` to the `serverInfo.name` field returned in the MCP `initialize` response, making the prototype status visible to any connected MCP client.

### Parameter mapping at invocation

```
MCP arguments JSON
      │
      ├── [MVCFromPath] params  → substituted into path template: /customers/{id} → /customers/42
      ├── [MVCFromQuery] params → appended as query string: ?page=2&pagesize=10
      └── [MVCFromBody] param   → request body, Content-Type: application/json
```

### HTTP response → TMCPToolResult

| HTTP status | Result |
|---|---|
| 2xx | `TMCPToolResult.Text(ResponseBody)` |
| 4xx | `TMCPToolResult.Error('HTTP NNN: ' + ResponseBody)` |
| 5xx | `TMCPToolResult.Error('HTTP NNN: ' + ResponseBody)` |
| timeout / network exception | `TMCPToolResult.Error('Network error: ' + Message)` |
| unexpected exception | `TMCPToolResult.Error('Internal error: ' + Message)` — never propagated |

### Instance model

One `TMCPBridgeProvider` instance is created per `RegisterFromEngine` call, covering **all** controllers of that engine. Tools from all controllers are registered in a single provider. This differs from the generated code, which produces one `TMCPToolProvider` subclass per controller.

### HTTP client lifecycle

One `TNetHTTPClient` instance per `TMCPBridgeProvider`, created in `Create`, freed in `Destroy`. Headers sent: `Content-Type: application/json`, `Accept: application/json`.

---

## Section 3: Code Generator (`TMCPBridgeCodeGen`)

### Output

One `.pas` file per discovered controller, written to `AOutputPath`. File naming: `MCP<ControllerName>ProviderU.pas` (e.g., `MCPCustomersProviderU.pas`).

### Generated file structure

```pascal
// *** GENERATED 2026-05-04 — REVIEW AND CURATE BEFORE PRODUCTION USE ***
// Source: TCustomersController
// Generator: MVCFramework.MCP.Bridge / GenerateProviderUnit

unit MCPCustomersProviderU;

interface

uses
  MVCFramework.MCP.ToolProvider, MVCFramework.MCP.Attributes,
  MVCFramework.MCP.Server, System.Net.HttpClient;

type
  TCustomersMCPProvider = class(TMCPToolProvider)
  private
    FBaseURL: string;
  public
    constructor Create; override;

    [MCPTool('get_customers', 'Returns paginated list of customers')]
    function GetCustomers(
      [MCPParam('Page number', False)] const page: Integer;
      [MCPParam('Page size', False)]   const pagesize: Integer
    ): TMCPToolResult;

    [MCPTool('get_customers_by_id', 'Returns a single customer by ID')]
    function GetCustomersById(
      [MCPParam('Customer ID')] const id: Integer
    ): TMCPToolResult;

    // TODO: add description (no [MVCDoc] found on action)
    [MCPTool('post_customers', '')]
    function PostCustomers(
      [MCPParam('Request body (JSON)')] const body: string
    ): TMCPToolResult;
  end;

implementation

constructor TCustomersMCPProvider.Create;
begin
  inherited;
  FBaseURL := 'http://localhost:8080'; // TODO: move to config / .env
end;

// ... method bodies: HTTP calls identical to the proxy

initialization
  TMCPServer.Instance.RegisterToolProvider(TCustomersMCPProvider);

end.
```

### TODO markers emitted

| Situation | Comment in generated code |
|---|---|
| No `[MVCDoc]` on action | `// TODO: add description` |
| Parameter without `MVCFrom*` | `// TODO: parameter 'X' has no MVCFrom* attribute — add manually` |
| Non-string/int/bool param type | `// TODO: verify JSON schema type for parameter 'X'` |
| `FBaseURL` hardcoded | `// TODO: move to config / .env` |

---

## Section 4: Error Handling

### At registration time (`RegisterFromEngine`)

| Situation | Behaviour |
|---|---|
| Duplicate tool name after controller prefix | `EMCPBridgeException` — fail fast, names both conflicting methods |
| Controller without `[MVCPath]` | Silently skipped |
| Action without `[MVCHTTPMethod]` | Silently skipped |
| Empty `ABaseURL` | `EMCPBridgeException` immediately |

### At generation time (`GenerateProviderUnit`)

| Situation | Behaviour |
|---|---|
| Output directory does not exist | `EMCPBridgeException` |
| File already exists | Overwritten silently (developer owns source control) |
| No bridge tools registered | Writes empty file with `// No bridge tools registered` comment |

---

## Section 5: Testing

No separate test project. Tests integrate into the existing `tests/testproject/`.

Coverage:
- `TMCPEngineScanner`: correct extraction of path/method/params from test controllers, including edge cases (mixed `MVCFrom*`, multiple placeholders, name collisions).
- `GenerateProviderUnit`: generated `.pas` contains expected `[MCPTool]` attributes and TODO markers.
- Proxy integration: `RegisterFromEngine` + `tools/list` + `tools/call` via `TMCPClient` against the existing test server.

---

## Integration with Existing Code

The only additions to existing files are two backwards-compatible virtual methods on `TMCPToolProvider` (`MVCFramework.MCP.ToolProvider.pas`), both with no-op default implementations:

```pascal
function GetDynamicTools: TArray<TMCPToolInfo>; virtual;
function InvokeDynamic(const AToolName: string; AParams: TJDOJsonObject): TMCPToolResult; virtual;
```

`TMCPServer` and `TMCPRequestHandler` check for non-empty `GetDynamicTools` and route accordingly. Existing providers return empty arrays from the default implementation — zero behaviour change.
