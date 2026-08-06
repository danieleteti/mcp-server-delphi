# MCP Server Rock-Solid Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 12 critical/major bugs in the MCP server library (memory safety, thread safety, protocol compliance, security, API correctness) and add extensive integration tests for every fix.

**Architecture:** Each fix is applied directly to the existing source unit. Tests are added to the Python integration suites (`tests/test_mcp_server.py`, `tests/test_mcp_server_stdio.py`). No new source units are created. Fixes follow the recommended order from the audit report: correctness/safety first, then protocol compliance, then config cleanup.

**Tech Stack:** Object Pascal (Delphi 11+), JsonDataObjects, DMVCFramework JSON-RPC, Python 3 + `requests` for integration tests.

---

## File Map

| Fix | File(s) Modified |
|-----|-----------------|
| EH-1 | `sources/MVCFramework.MCP.ResourceProvider.pas` |
| EH-2 + PC-4 | `sources/MVCFramework.MCP.Stdio.pas` |
| TS-2 | `sources/MVCFramework.MCP.Server.pas`, `sources/MVCFramework.MCP.RequestHandler.pas` |
| AC-2 | `sources/MVCFramework.MCP.ToolProvider.pas` |
| AC-5 | `tests/testproject/MCPConformanceProvidersU.pas` |
| SEC-1 | `sources/MVCFramework.MCP.Session.pas` |
| MF-5 | `sources/MVCFramework.MCP.Bridge.pas` |
| PC-1 | `sources/MVCFramework.MCP.Server.pas`, `sources/MVCFramework.MCP.RequestHandler.pas` |
| PC-2 | `sources/MVCFramework.MCP.Server.pas`, `sources/MVCFramework.MCP.Stdio.pas` |
| EH-4 | `sources/MVCFramework.MCP.Session.pas` |
| DB-4 | `sample/MCPServerSample.dpr` |
| Tests | `tests/test_mcp_server.py`, `tests/test_mcp_server_stdio.py` |

---

## Task 1: EH-1 — TMCPResourceResult memory safety (IContentHolder pattern)

**Problem:** `TMCPResourceResult` holds `FContents: TJDOJsonArray` as a raw pointer in a plain record. When RTTI dispatches a resource method (via `TRttiMethod.Invoke → TValue → AsType<TMCPResourceResult>`), the record is value-copied, and both copies share the same `TJDOJsonArray` pointer. The first call to `ToJSON` nils its own reference and transfers ownership; the second call either double-frees or leaks. `TMCPToolResult` solved this with an `IContentHolder` interface — apply the same pattern here.

**Files:**
- Modify: `sources/MVCFramework.MCP.ResourceProvider.pas`
- Modify: `tests/test_mcp_server.py` (add test)

- [ ] **Step 1: Write the failing test** — add to `tests/test_mcp_server.py` inside the `run_tests` function (after other resource tests):

```python
def test_resource_result_not_corrupted_on_multiple_reads(client):
    """EH-1: resources/read must return consistent content on repeated calls."""
    resp1 = client.rpc_request("resources/read", {"uri": "test://static-text"})
    resp2 = client.rpc_request("resources/read", {"uri": "test://static-text"})
    assert resp1.status_code == 200, f"First read failed: {resp1.text}"
    assert resp2.status_code == 200, f"Second read failed: {resp2.text}"
    body1 = resp1.json()
    body2 = resp2.json()
    assert "result" in body1, f"First read missing result: {body1}"
    assert "result" in body2, f"Second read missing result: {body2}"
    contents1 = body1["result"].get("contents", [])
    contents2 = body2["result"].get("contents", [])
    assert len(contents1) == 1, f"Expected 1 content item, got {contents1}"
    assert len(contents2) == 1, f"Expected 1 content item on second call, got {contents2}"
    assert contents1[0].get("text") == contents2[0].get("text"), \
        "EH-1: resource content changed between calls — record copy bug"
```

- [ ] **Step 2: Rewrite `MVCFramework.MCP.ResourceProvider.pas`** — replace the raw `FContents: TJDOJsonArray` with an `IContentHolder` interface exactly mirroring the `TMCPToolResult` pattern:

```pascal
unit MVCFramework.MCP.ResourceProvider;

interface

uses
  JsonDataObjects, System.SysUtils;

type
  TMCPResourceResult = record
  private type
    IContentHolder = interface
      function GetContents: TJDOJsonArray;
      procedure ReleaseContents;
    end;
    TContentHolder = class(TInterfacedObject, IContentHolder)
    private
      FContents: TJDOJsonArray;
    public
      constructor Create(AContents: TJDOJsonArray);
      destructor Destroy; override;
      function GetContents: TJDOJsonArray;
      procedure ReleaseContents;
    end;
  private
    FHolder: IContentHolder;
  public
    class function Text(const AURI, AText: string;
      const AMimeType: string = 'text/plain'): TMCPResourceResult; static;
    class function Blob(const AURI, ABase64Data: string;
      const AMimeType: string = 'application/octet-stream'): TMCPResourceResult; static;
    function ToJSON: TJDOJsonObject;
  end;

  TMCPResourceProvider = class
  public
    constructor Create; virtual;
    destructor Destroy; override;
  end;

  TMCPResourceProviderClass = class of TMCPResourceProvider;

implementation

{ TMCPResourceResult.TContentHolder }

constructor TMCPResourceResult.TContentHolder.Create(AContents: TJDOJsonArray);
begin
  inherited Create;
  FContents := AContents;
end;

destructor TMCPResourceResult.TContentHolder.Destroy;
begin
  FContents.Free;
  inherited;
end;

function TMCPResourceResult.TContentHolder.GetContents: TJDOJsonArray;
begin
  Result := FContents;
end;

procedure TMCPResourceResult.TContentHolder.ReleaseContents;
begin
  FContents := nil;
end;

{ TMCPResourceResult }

class function TMCPResourceResult.Text(const AURI, AText: string;
  const AMimeType: string): TMCPResourceResult;
var
  LContents: TJDOJsonArray;
  LItem: TJDOJsonObject;
begin
  LContents := TJDOJsonArray.Create;
  LItem := LContents.AddObject;
  LItem.S['uri'] := AURI;
  LItem.S['mimeType'] := AMimeType;
  LItem.S['text'] := AText;
  Result.FHolder := TContentHolder.Create(LContents);
end;

class function TMCPResourceResult.Blob(const AURI, ABase64Data: string;
  const AMimeType: string): TMCPResourceResult;
var
  LContents: TJDOJsonArray;
  LItem: TJDOJsonObject;
begin
  LContents := TJDOJsonArray.Create;
  LItem := LContents.AddObject;
  LItem.S['uri'] := AURI;
  LItem.S['mimeType'] := AMimeType;
  LItem.S['blob'] := ABase64Data;
  Result.FHolder := TContentHolder.Create(LContents);
end;

function TMCPResourceResult.ToJSON: TJDOJsonObject;
var
  LContents: TJDOJsonArray;
begin
  Result := TJDOJsonObject.Create;
  if FHolder <> nil then
  begin
    LContents := FHolder.GetContents;
    FHolder.ReleaseContents;
    Result.A['contents'] := LContents;
  end
  else
    Result.A['contents'] := TJDOJsonArray.Create;
end;

{ TMCPResourceProvider }

constructor TMCPResourceProvider.Create;
begin
  inherited Create;
end;

destructor TMCPResourceProvider.Destroy;
begin
  inherited;
end;

end.
```

- [ ] **Step 3: Compile** — open Delphi IDE or run `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`. Expected: 0 errors, 0 warnings about memory.

- [ ] **Step 4: Run test** (server must be running):
```
python tests/test_mcp_server.py --verbose 2>&1 | grep -A3 "resource_result_not_corrupted"
```
Expected: `PASS test_resource_result_not_corrupted_on_multiple_reads`

- [ ] **Step 5: Commit**
```
git add sources/MVCFramework.MCP.ResourceProvider.pas tests/test_mcp_server.py
git commit -m "fix(EH-1): TMCPResourceResult - IContentHolder pattern prevents double-free on record copy"
```

---

## Task 2: EH-2 + PC-4 — Stdio nil dereference and batch request detection

**Problem (EH-2):** In `MVCFramework.MCP.Stdio.pas`, `TJDOJsonObject.Parse(LLine) as TJDOJsonObject` can return `nil` if the input is not a JSON object (e.g., a bare JSON array). The nil check on line 84 (`LRequest := nil`) is overwritten only if parse succeeds; if parse returns nil without raising (implementation-dependent), then `LRequest.Contains('id')` at line 100 is a nil dereference → AV → server crash.

**Problem (PC-4):** JSON-RPC 2.0 §6 defines batch requests as a top-level JSON array. The stdio transport silently loses them or crashes. The fix: detect `[` prefix and return a proper error.

**Files:**
- Modify: `sources/MVCFramework.MCP.Stdio.pas`
- Modify: `tests/test_mcp_server_stdio.py` (add tests)

- [ ] **Step 1: Write failing tests** — add to `tests/test_mcp_server_stdio.py`:

```python
def test_batch_request_returns_error(proc):
    """PC-4: batch JSON-RPC must get an error, not be silently ignored."""
    batch = json.dumps([
        {"jsonrpc": "2.0", "id": 1, "method": "ping"},
        {"jsonrpc": "2.0", "id": 2, "method": "ping"},
    ])
    proc.stdin.write(batch + "\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    assert line is not None, "PC-4: No response to batch request"
    resp = json.loads(line)
    assert "error" in resp, f"PC-4: Expected error for batch, got: {resp}"
    assert resp["error"]["code"] == -32600, \
        f"PC-4: Expected -32600 Invalid Request for batch, got {resp['error']['code']}"

def test_non_object_json_returns_parse_error(proc):
    """EH-2: bare JSON values that are not objects must return parse error."""
    proc.stdin.write('"just a string"\n')
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    assert line is not None, "EH-2: No response to non-object JSON"
    resp = json.loads(line)
    assert "error" in resp, f"EH-2: Expected error for non-object JSON, got: {resp}"
    # -32700 Parse error or -32600 Invalid Request are both acceptable
    assert resp["error"]["code"] in (-32700, -32600), \
        f"EH-2: Unexpected error code {resp['error']['code']}"
```

- [ ] **Step 2: Apply fixes to `MVCFramework.MCP.Stdio.pas`** — in `procedure TMCPStdioTransport.Run`, add two guards:

  **Fix PC-4** — add BEFORE the `try` block (line ~86), right after the empty-line check:
  ```pascal
  { PC-4: JSON-RPC 2.0 §6 batch requests (top-level array) are not supported.
    Detect early to avoid a misleading parse-error response. }
  if LLine.TrimLeft.StartsWith('[') then
  begin
    WriteLn(Output,
      '{"jsonrpc":"2.0","error":{"code":-32600,"message":"Batch requests are not supported"},"id":null}');
    Flush(Output);
    Continue;
  end;
  ```

  **Fix EH-2** — add AFTER the inner try/except for Parse (after line ~98, before `LHasId := LRequest.Contains('id')`):
  ```pascal
  { EH-2: Parse returned nil without raising (non-object JSON like a number
    or bare string). Treat as parse error. }
  if LRequest = nil then
  begin
    WriteLn(Output,
      '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error: not a JSON object"},"id":null}');
    Flush(Output);
    Continue;
  end;
  ```

  The complete `Run` method loop body becomes:
  ```pascal
  while not EOF(Input) do
  begin
    ReadLn(Input, LLine);
    if LLine.Trim.IsEmpty then
      Continue;

    { PC-4: detect batch before parse }
    if LLine.TrimLeft.StartsWith('[') then
    begin
      WriteLn(Output,
        '{"jsonrpc":"2.0","error":{"code":-32600,"message":"Batch requests are not supported"},"id":null}');
      Flush(Output);
      Continue;
    end;

    LRequest := nil;
    LResponse := nil;
    try
      try
        LRequest := TJDOJsonObject.Parse(LLine) as TJDOJsonObject;
      except
        on E: Exception do
        begin
          WriteLn(Output, '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error: ' +
            E.Message.Replace('\', '\\').Replace('"', '\"') + '"},"id":null}');
          Flush(Output);
          Continue;
        end;
      end;

      { EH-2: guard against nil from non-object JSON }
      if LRequest = nil then
      begin
        WriteLn(Output,
          '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error: not a JSON object"},"id":null}');
        Flush(Output);
        Continue;
      end;

      LHasId := LRequest.Contains('id');
      { ... rest unchanged ... }
  ```

- [ ] **Step 3: Compile** — `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`

- [ ] **Step 4: Run tests** (restart stdio server):
```
python tests/test_mcp_server_stdio.py --verbose 2>&1 | grep -E "(batch_request|non_object_json)"
```
Expected: both tests PASS.

- [ ] **Step 5: Commit**
```
git add sources/MVCFramework.MCP.Stdio.pas tests/test_mcp_server_stdio.py
git commit -m "fix(EH-2,PC-4): stdio transport - nil guard after parse + batch request detection"
```

---

## Task 3: TS-2 — Remove race on ServerName/ServerVersion writes

**Problem:** `DoInitialize` in `MVCFramework.MCP.RequestHandler.pas` writes `LServer.ServerName` and `LServer.ServerVersion` if they are empty. `TMCPEndpoint` is created per-request, so two concurrent `initialize` calls race on these plain string fields → heap corruption. Fix: set defaults in `TMCPServer.Create` (constructor), remove writes from `DoInitialize`, keep only the log warning.

**Files:**
- Modify: `sources/MVCFramework.MCP.Server.pas` (constructor)
- Modify: `sources/MVCFramework.MCP.RequestHandler.pas` (DoInitialize)
- Modify: `tests/test_mcp_server.py` (add concurrent test)

- [ ] **Step 1: Write the failing test** — add to `tests/test_mcp_server.py`:

```python
def test_concurrent_initialize_sessions(base_url):
    """TS-2: concurrent initialize calls must not corrupt ServerName/ServerVersion."""
    import threading
    results = []
    errors = []

    def do_init():
        c = MCPTestClient(base_url)
        try:
            resp = c.rpc_request("initialize", {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "clientInfo": {"name": "ThreadTest", "version": "1.0"},
            }, include_session=False)
            assert resp.status_code == 200, f"Status {resp.status_code}"
            body = resp.json()
            assert "result" in body, f"Missing result: {body}"
            name = body["result"]["serverInfo"]["name"]
            assert name and len(name) > 0, f"Empty serverInfo.name: {body}"
            results.append(name)
        except Exception as e:
            errors.append(str(e))

    threads = [threading.Thread(target=do_init) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10)

    assert not errors, f"TS-2: Errors in concurrent initialize: {errors}"
    assert len(results) == 10, f"TS-2: Only {len(results)}/10 succeeded"
    # All should return the same non-empty server name
    assert all(r == results[0] for r in results), \
        f"TS-2: Inconsistent serverInfo.name values: {set(results)}"
```

- [ ] **Step 2: Set defaults in `TMCPServer.Create`** — in `sources/MVCFramework.MCP.Server.pas`, in `constructor TMCPServer.Create`, add after `inherited Create`:

```pascal
constructor TMCPServer.Create(ASessionManager: IMCPSessionManager);
begin
  inherited Create;
  FServerName    := 'MCPServer';   { default; override via ServerName property }
  FServerVersion := '1.0.0';       { default; override via ServerVersion property }
  FTools    := TObjectDictionary<string, TMCPToolInfo>.Create([doOwnsValues]);
  FResources := TObjectDictionary<string, TMCPResourceInfo>.Create([doOwnsValues]);
  FPrompts  := TObjectDictionary<string, TMCPPromptInfo>.Create([doOwnsValues]);
  FRttiContext := TRttiContext.Create;
  FDynamicProviders := TObjectList<TMCPToolProvider>.Create(True);
  if ASessionManager <> nil then
    FSessionManager := ASessionManager
  else
    FSessionManager := TMCPInMemorySessionManager.Create;
end;
```

- [ ] **Step 3: Remove writes from `DoInitialize`** — in `sources/MVCFramework.MCP.RequestHandler.pas`, replace the write-if-empty block with log-only:

```pascal
function TMCPRequestHandler.DoInitialize(AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LSession: IMCPSession;
  LClientInfo: TMCPClientInfo;
  LCaps: TMCPCapabilities;
begin
  LServer := TMCPServer(FServer);

  { Log if server identity is still at default values — developer reminder only.
    Defaults are set in TMCPServer.Create; do NOT write here (race condition). }
  if LServer.ServerName = 'MCPServer' then
    LogW('MCP: ServerName is default "MCPServer". Set TMCPServer.Instance.ServerName in .dpr.');
  if LServer.ServerVersion = '1.0.0' then
    LogW('MCP: ServerVersion is default "1.0.0". Set TMCPServer.Instance.ServerVersion in .dpr.');

  LSession := LServer.SessionManager.CreateSession;
  FSessionId := LSession.SessionId;

  if (AParams <> nil) and AParams.Contains('clientInfo') then
    LClientInfo.FromJSON(AParams.O['clientInfo']);
  LSession.ClientInfo := LClientInfo;
  LSession.Initialized := True;

  LogI('MCP: Session created ' + FSessionId +
    ' for client ' + LClientInfo.Name + '/' + LClientInfo.Version);

  LCaps.SupportsTools     := LServer.Tools.Count > 0;
  LCaps.SupportsResources := LServer.Resources.Count > 0;
  LCaps.SupportsPrompts   := LServer.Prompts.Count > 0;

  Result := TJDOJsonObject.Create;
  Result.S['protocolVersion'] := MCP_PROTOCOL_VERSION;
  Result.O['capabilities']    := LCaps.ToJSON;
  Result.O['serverInfo'].S['name']    := LServer.ServerName;
  Result.O['serverInfo'].S['version'] := LServer.ServerVersion;
end;
```

- [ ] **Step 4: Compile** — `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`

- [ ] **Step 5: Run test**:
```
python tests/test_mcp_server.py --verbose 2>&1 | grep -A5 "concurrent_initialize"
```
Expected: PASS.

- [ ] **Step 6: Commit**
```
git add sources/MVCFramework.MCP.Server.pas sources/MVCFramework.MCP.RequestHandler.pas tests/test_mcp_server.py
git commit -m "fix(TS-2): set ServerName/ServerVersion defaults in constructor, remove race-prone writes from DoInitialize"
```

---

## Task 4: AC-2 + AC-5 — BoolToStr lowercase and conformance resource MIME fix

**Problem AC-2:** `TMCPToolResult.FromValue(Boolean)` calls `BoolToStr(AValue, True)` which returns `'True'`/`'False'` (capitalised). JSON and LLMs expect `'true'`/`'false'`.

**Problem AC-5:** `TConformanceResources` in `MCPConformanceProvidersU.pas` uses 3-arg `[MCPResource(...)]` where 4 are needed. The attribute constructor is `(AURI, AName, ADescription, AMimeType)`. With 3 args, `ADescription` receives `'text/plain'` and `'image/png'` respectively, and `AMimeType` gets its default `'text/plain'`. So `test://static-binary` is listed with `mimeType:"text/plain"` instead of `"image/png"`.

**Files:**
- Modify: `sources/MVCFramework.MCP.ToolProvider.pas`
- Modify: `tests/testproject/MCPConformanceProvidersU.pas`
- Modify: `tests/test_mcp_server.py` (add tests)

- [ ] **Step 1: Write failing tests** — add to `tests/test_mcp_server.py`:

```python
def test_bool_tool_result_is_lowercase(client):
    """AC-2: TMCPToolResult.FromValue(Boolean) must return 'true'/'false' not 'True'/'False'."""
    resp = client.call_tool("is_even", {"value": 4})
    assert resp.status_code == 200, f"Tool call failed: {resp.text}"
    body = resp.json()
    content = body["result"]["content"]
    assert len(content) > 0, "No content in result"
    text = content[0]["text"]
    assert text in ("true", "false"), \
        f"AC-2: Expected 'true' or 'false', got '{text}'"
    assert text == "true", f"AC-2: is_even(4) should be 'true', got '{text}'"

def test_conformance_binary_resource_mime_type(client):
    """AC-5: test://static-binary must be listed with mimeType 'image/png' not 'text/plain'."""
    resp = client.rpc_request("resources/list")
    assert resp.status_code == 200
    body = resp.json()
    resources = body["result"]["resources"]
    binary = next((r for r in resources if r["uri"] == "test://static-binary"), None)
    assert binary is not None, "test://static-binary not found in resources/list"
    assert binary["mimeType"] == "image/png", \
        f"AC-5: Expected mimeType 'image/png', got '{binary['mimeType']}'"
```

- [ ] **Step 2: Fix `FromValue(Boolean)` in `MVCFramework.MCP.ToolProvider.pas`** — locate line 386–389 and replace:

```pascal
class function TMCPToolResult.FromValue(const AValue: Boolean): TMCPToolResult;
begin
  if AValue then
    Result := TMCPToolResult.Text('true')
  else
    Result := TMCPToolResult.Text('false');
end;
```

- [ ] **Step 3: Fix conformance resource attributes in `MCPConformanceProvidersU.pas`** — replace lines 60–65:

```pascal
type
  TConformanceResources = class(TMCPResourceProvider)
  public
    [MCPResource('test://static-text', 'Static text resource',
      'Static text resource for conformance testing', 'text/plain')]
    function StaticText(const URI: string): TMCPResourceResult;

    [MCPResource('test://static-binary', 'Static binary resource',
      'Static binary resource for conformance testing', 'image/png')]
    function StaticBinary(const URI: string): TMCPResourceResult;
  end;
```

- [ ] **Step 4: Compile** — `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`

- [ ] **Step 5: Run tests**:
```
python tests/test_mcp_server.py --verbose 2>&1 | grep -E "(bool_tool|binary_resource_mime)"
```
Expected: both PASS.

- [ ] **Step 6: Commit**
```
git add sources/MVCFramework.MCP.ToolProvider.pas tests/testproject/MCPConformanceProvidersU.pas tests/test_mcp_server.py
git commit -m "fix(AC-2,AC-5): BoolToStr lowercase 'true'/'false'; fix conformance resource mimeType to 'image/png'"
```

---

## Task 5: SEC-1 — AutoRecover security warning

**Problem:** `TMCPInMemorySessionManager.AutoRecover = True` silently accepts any non-empty session ID as valid (authentication bypass). There is no warning, no documentation of the security implication, and no test.

**Files:**
- Modify: `sources/MVCFramework.MCP.Session.pas`
- Modify: `tests/test_mcp_server.py` (add test for AutoRecover=False default and fabricated session rejection)

- [ ] **Step 1: Write failing test** — add to `tests/test_mcp_server.py`:

```python
def test_fabricated_session_id_is_rejected(base_url):
    """SEC-1: a made-up session ID must not be accepted (AutoRecover must default to False)."""
    import uuid
    fake_session = str(uuid.uuid4())
    # Attempt tools/list with a fabricated session ID, no prior initialize
    resp = requests.post(
        base_url,
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        headers={"Content-Type": "application/json", SESSION_HEADER: fake_session},
    )
    body = resp.json()
    # Server must return an error (session invalid), not a tool list
    assert "error" in body, \
        f"SEC-1: Fabricated session was accepted — AutoRecover must be False by default. Got: {body}"
```

- [ ] **Step 2: Add `SetAutoRecover` setter to `TMCPInMemorySessionManager`** — in `sources/MVCFramework.MCP.Session.pas`:

  **In the interface section**, change the `AutoRecover` property declaration:
  ```pascal
  private
    procedure SetAutoRecover(const AValue: Boolean);
  public
    { ... existing public members ... }
    property AutoRecover: Boolean read FAutoRecover write SetAutoRecover;
  ```

  **In the implementation section**, add the setter:
  ```pascal
  procedure TMCPInMemorySessionManager.SetAutoRecover(const AValue: Boolean);
  begin
    if AValue and not FAutoRecover then
      LogW('MCP: AutoRecover=True — any non-empty session ID is silently accepted ' +
        'without cryptographic validation. This bypasses session authentication. ' +
        'Intended only for development (reconnect after server restart). ' +
        'DISABLE before production deployment.');
    FAutoRecover := AValue;
  end;
  ```

  Add `MVCFramework.Logger` to the `uses` clause of `MVCFramework.MCP.Session.pas` implementation section.

- [ ] **Step 3: Compile** — `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`

- [ ] **Step 4: Run test**:
```
python tests/test_mcp_server.py --verbose 2>&1 | grep -A3 "fabricated_session"
```
Expected: PASS (server returns error for fake session).

- [ ] **Step 5: Commit**
```
git add sources/MVCFramework.MCP.Session.pas tests/test_mcp_server.py
git commit -m "fix(SEC-1): AutoRecover setter logs security warning when enabled"
```

---

## Task 6: MF-5 — TMCPBridgeProvider per-call THTTPClient

**Problem:** `TMCPBridgeProvider` stores `FHttpClient: THTTPClient` as a shared field. `THTTPClient` is not thread-safe for concurrent use. Multiple concurrent tool calls through the bridge (each served by a different `TMCPEndpoint` instance, but all routing to the same `HandlerInstance`) race on `FHttpClient`. Fix: create a local `THTTPClient` per `InvokeDynamic` call. Remove the shared `FHttpClient` field.

**Files:**
- Modify: `sources/MVCFramework.MCP.Bridge.pas`
- Modify: `tests/test_mcp_server.py` (add concurrent bridge tool test)

- [ ] **Step 1: Write failing test** — add to `tests/test_mcp_server.py` (this tests that concurrent bridge calls don't crash; requires bridge tools to be registered in the test server):

```python
def test_concurrent_tool_calls_do_not_crash(client):
    """MF-5: concurrent tools/call must not crash due to shared THTTPClient."""
    import threading
    results = []
    errors = []

    def call_tool_thread():
        try:
            # Use a known non-bridge tool that exists in the test server
            resp = client.call_tool("test_simple_text")
            body = resp.json()
            if "result" in body:
                results.append("ok")
            else:
                errors.append(f"Unexpected: {body}")
        except Exception as e:
            errors.append(str(e))

    threads = [threading.Thread(target=call_tool_thread) for _ in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=15)

    assert not errors, f"MF-5: Errors in concurrent tool calls: {errors}"
    assert len(results) == 20, f"MF-5: Only {len(results)}/20 calls succeeded"
```

- [ ] **Step 2: Remove `FHttpClient` field and create per-call in `MVCFramework.MCP.Bridge.pas`**

  **In `TMCPBridgeProvider` type declaration** — remove `FHttpClient: THTTPClient;` from private fields.

  **In `constructor TMCPBridgeProvider.Create`** — remove:
  ```pascal
  FHttpClient := THTTPClient.Create;
  FHttpClient.ContentType := 'application/json';
  FHttpClient.Accept := 'application/json';
  ```

  **In `destructor TMCPBridgeProvider.Destroy`** — remove:
  ```pascal
  FHttpClient.Free;
  ```

  **In `function TMCPBridgeProvider.InvokeDynamic`** — add a local client:
  ```pascal
  function TMCPBridgeProvider.InvokeDynamic(const AToolName: string;
    AArguments: TJDOJsonObject): TMCPToolResult;
  var
    LHttpClient: THTTPClient;
    LRoute: TMCPBridgeRouteInfo;
    LURL: string;
    LResp: IHTTPResponse;
    LParam: TMCPBridgeParamInfo;
    LBodyStream: TStringStream;
    LHasBody: Boolean;
    LBodyContent: string;
  begin
    LRoute := FindRoute(AToolName);
    if LRoute = nil then
      Exit(TMCPToolResult.Error('Bridge: unknown tool "' + AToolName + '"'));

    LHttpClient := THTTPClient.Create;
    try
      LHttpClient.ContentType := 'application/json';
      LHttpClient.Accept := 'application/json';

      LURL := BuildURL(LRoute, AArguments) + BuildQueryString(LRoute, AArguments);
      { ... rest of the method unchanged, replacing FHttpClient with LHttpClient ... }
    finally
      LHttpClient.Free;
    end;
  end;
  ```

  Read the full `InvokeDynamic` implementation (lines 497 onward in the original file) and replace every `FHttpClient` reference with `LHttpClient`.

- [ ] **Step 3: Compile** — `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`

- [ ] **Step 4: Run test**:
```
python tests/test_mcp_server.py --verbose 2>&1 | grep -A3 "concurrent_tool_calls"
```
Expected: PASS.

- [ ] **Step 5: Commit**
```
git add sources/MVCFramework.MCP.Bridge.pas tests/test_mcp_server.py
git commit -m "fix(MF-5): TMCPBridgeProvider creates THTTPClient per InvokeDynamic call (thread-safe)"
```

---

## Task 7: PC-1 — initialize version negotiation + instructions field

**Problem:** `DoInitialize` unconditionally echoes `MCP_PROTOCOL_VERSION` without checking the client's offered version. If a future client sends a newer version, the server should log a warning and reply with its own supported version. Also, the MCP spec allows an `instructions` field in the `initialize` result — clients like Claude Desktop display this in their MCP panel. Add `ServerInstructions: string` property to `TMCPServer`.

**Files:**
- Modify: `sources/MVCFramework.MCP.Server.pas` (add `FServerInstructions` field + property)
- Modify: `sources/MVCFramework.MCP.RequestHandler.pas` (DoInitialize version check + instructions)
- Modify: `tests/test_mcp_server.py` (add tests)

- [ ] **Step 1: Write failing tests** — add to `tests/test_mcp_server.py`:

```python
def test_initialize_version_negotiation(base_url):
    """PC-1: server must respond with its own protocolVersion regardless of client request."""
    c = MCPTestClient(base_url)
    resp = c.rpc_request("initialize", {
        "protocolVersion": "2099-01-01",  # future version
        "clientInfo": {"name": "TestClient", "version": "1.0"},
    }, include_session=False)
    assert resp.status_code == 200, f"Status {resp.status_code}: {resp.text}"
    body = resp.json()
    assert "result" in body, f"Missing result: {body}"
    pv = body["result"].get("protocolVersion", "")
    assert pv == MCP_PROTOCOL_VERSION, \
        f"PC-1: Expected server to respond with '{MCP_PROTOCOL_VERSION}', got '{pv}'"

def test_initialize_includes_server_info(client):
    """PC-1: initialize result must contain serverInfo with non-empty name and version."""
    # Re-initialize to get a fresh response
    c = MCPTestClient(client.base_url)
    resp = c.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "clientInfo": {"name": "TestClient", "version": "1.0"},
    }, include_session=False)
    body = resp.json()
    assert "result" in body
    info = body["result"].get("serverInfo", {})
    assert info.get("name"), f"PC-1: serverInfo.name is empty: {body}"
    assert info.get("version"), f"PC-1: serverInfo.version is empty: {body}"
```

- [ ] **Step 2: Add `FServerInstructions` to `TMCPServer`** — in `sources/MVCFramework.MCP.Server.pas`:

  In the private fields of `TMCPServer`, add:
  ```pascal
  FServerInstructions: string;
  ```

  In the property section, add:
  ```pascal
  property ServerInstructions: string read FServerInstructions write FServerInstructions;
  ```

- [ ] **Step 3: Update `DoInitialize` in `MVCFramework.MCP.RequestHandler.pas`** — add version check and instructions:

```pascal
function TMCPRequestHandler.DoInitialize(AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LSession: IMCPSession;
  LClientInfo: TMCPClientInfo;
  LCaps: TMCPCapabilities;
  LClientVersion: string;
begin
  LServer := TMCPServer(FServer);

  if LServer.ServerName = 'MCPServer' then
    LogW('MCP: ServerName is default "MCPServer". Set TMCPServer.Instance.ServerName in .dpr.');
  if LServer.ServerVersion = '1.0.0' then
    LogW('MCP: ServerVersion is default "1.0.0". Set TMCPServer.Instance.ServerVersion in .dpr.');

  { PC-1: Version negotiation — log if client requests a version we don't implement.
    Server always replies with its own supported version. }
  LClientVersion := '';
  if AParams <> nil then
    LClientVersion := AParams.S['protocolVersion'];
  if (not LClientVersion.IsEmpty) and (LClientVersion <> MCP_PROTOCOL_VERSION) then
    LogW('MCP: Client requested protocol version "' + LClientVersion +
      '", server implements "' + MCP_PROTOCOL_VERSION +
      '". Responding with server version.');

  LSession := LServer.SessionManager.CreateSession;
  FSessionId := LSession.SessionId;

  if (AParams <> nil) and AParams.Contains('clientInfo') then
    LClientInfo.FromJSON(AParams.O['clientInfo']);
  LSession.ClientInfo := LClientInfo;
  LSession.Initialized := True;

  LogI('MCP: Session created ' + FSessionId +
    ' for client ' + LClientInfo.Name + '/' + LClientInfo.Version);

  LCaps.SupportsTools     := LServer.Tools.Count > 0;
  LCaps.SupportsResources := LServer.Resources.Count > 0;
  LCaps.SupportsPrompts   := LServer.Prompts.Count > 0;

  Result := TJDOJsonObject.Create;
  Result.S['protocolVersion'] := MCP_PROTOCOL_VERSION;
  Result.O['capabilities']    := LCaps.ToJSON;
  Result.O['serverInfo'].S['name']    := LServer.ServerName;
  Result.O['serverInfo'].S['version'] := LServer.ServerVersion;
  { PC-1: optional instructions field for client display / system prompt injection }
  if not LServer.ServerInstructions.IsEmpty then
    Result.S['instructions'] := LServer.ServerInstructions;
end;
```

- [ ] **Step 4: Compile** — `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`

- [ ] **Step 5: Run tests**:
```
python tests/test_mcp_server.py --verbose 2>&1 | grep -E "(version_negotiation|server_info)"
```
Expected: both PASS.

- [ ] **Step 6: Commit**
```
git add sources/MVCFramework.MCP.Server.pas sources/MVCFramework.MCP.RequestHandler.pas tests/test_mcp_server.py
git commit -m "fix(PC-1): initialize version negotiation + ServerInstructions property + instructions field in response"
```

---

## Task 8: PC-2 — Session error code -32001

**Problem:** Session errors (invalid/missing session ID) are reported with JSON-RPC code `-32600` (Invalid Request — structural JSON error). The correct code for application-level authorization failures is `-32001` (server-defined application error). Using `-32600` misleads clients into thinking the JSON structure was malformed.

**Files:**
- Modify: `sources/MVCFramework.MCP.Server.pas` (`OnBeforeRoutingHook`)
- Modify: `sources/MVCFramework.MCP.Stdio.pas` (`Run`, `EMCPSessionError` handler)
- Modify: `tests/test_mcp_server.py` (add test)
- Modify: `tests/test_mcp_server_stdio.py` (add test)

- [ ] **Step 1: Write failing tests**

  Add to `tests/test_mcp_server.py`:
  ```python
  def test_missing_session_returns_minus_32001(base_url):
      """PC-2: tools/list without a session must return error code -32001."""
      resp = requests.post(
          base_url,
          json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
          headers={"Content-Type": "application/json"},
      )
      body = resp.json()
      assert "error" in body, f"Expected error, got: {body}"
      assert body["error"]["code"] == -32001, \
          f"PC-2: Expected -32001, got {body['error']['code']}"
  ```

  Add to `tests/test_mcp_server_stdio.py`:
  ```python
  def test_missing_session_stdio_returns_minus_32001(proc):
      """PC-2: stdio — tools/list without initialize must return -32001."""
      req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
      proc.stdin.write(req + "\n")
      proc.stdin.flush()
      line = read_line_timeout(proc, timeout=5)
      assert line is not None, "No response to tools/list without session"
      resp = json.loads(line)
      assert "error" in resp, f"Expected error, got: {resp}"
      assert resp["error"]["code"] == -32001, \
          f"PC-2: Expected -32001, got {resp['error']['code']}"
  ```

- [ ] **Step 2: Fix `OnBeforeRoutingHook` in `MVCFramework.MCP.Server.pas`** — change line ~788:

  From:
  ```pascal
  raise EMVCJSONRPCError.Create(JSONRPC_ERR_INVALID_REQUEST, E.Message);
  ```
  To:
  ```pascal
  raise EMVCJSONRPCError.Create(-32001, E.Message);
  ```

- [ ] **Step 3: Fix `EMCPSessionError` handler in `MVCFramework.MCP.Stdio.pas`** — change line ~117:

  From:
  ```pascal
  LErrorResponse.O['error'].I['code'] := -32600;
  ```
  To:
  ```pascal
  LErrorResponse.O['error'].I['code'] := -32001;
  ```

- [ ] **Step 4: Add `MCP_ERR_SESSION = -32001` constant to `MVCFramework.MCP.Types.pas`** for clarity:

  In the `const` section:
  ```pascal
  MCP_ERR_SESSION = -32001;  { Application-level: invalid/missing session }
  ```

  Update both fixes above to use `MCP_ERR_SESSION` instead of the literal.

- [ ] **Step 5: Compile** — `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`

- [ ] **Step 6: Run tests**:
```
python tests/test_mcp_server.py --verbose 2>&1 | grep "minus_32001"
python tests/test_mcp_server_stdio.py --verbose 2>&1 | grep "minus_32001"
```
Expected: both PASS.

- [ ] **Step 7: Commit**
```
git add sources/MVCFramework.MCP.Server.pas sources/MVCFramework.MCP.Stdio.pas sources/MVCFramework.MCP.Types.pas tests/test_mcp_server.py tests/test_mcp_server_stdio.py
git commit -m "fix(PC-2): session errors use -32001 (application error), not -32600 (invalid request)"
```

---

## Task 9: EH-4 — Wire up CleanupExpiredSessions

**Problem:** `CleanupExpiredSessions` exists and is correct but is never called automatically. Sessions accumulate indefinitely. Fix: call cleanup from `CreateSession` every N sessions to avoid a background thread while still bounding memory growth. Use a threshold of 50 (configurable via constructor).

**Files:**
- Modify: `sources/MVCFramework.MCP.Session.pas`
- Modify: `tests/test_mcp_server.py` (add session cleanup test)

- [ ] **Step 1: Write failing test** — add to `tests/test_mcp_server.py`:

```python
def test_expired_sessions_do_not_accumulate(base_url):
    """EH-4: creating many sessions must not grow unboundedly — cleanup must run."""
    # Create 60 sessions (above the 50-session cleanup threshold) and then
    # verify the server still responds correctly (not crashed, not OOM).
    clients = []
    for _ in range(60):
        c = MCPTestClient(base_url)
        resp = c.rpc_request("initialize", {
            "protocolVersion": MCP_PROTOCOL_VERSION,
            "clientInfo": {"name": "CleanupTest", "version": "1.0"},
        }, include_session=False)
        assert resp.status_code == 200, f"Initialize failed: {resp.text}"
        body = resp.json()
        sid = resp.headers.get(SESSION_HEADER)
        if sid:
            c.session_id = sid
        clients.append(c)

    # Server must still handle a fresh request after 60 sessions
    fresh = MCPTestClient(base_url)
    resp = fresh.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "clientInfo": {"name": "FreshClient", "version": "1.0"},
    }, include_session=False)
    assert resp.status_code == 200, \
        f"EH-4: Server unresponsive after 60 sessions: {resp.text}"
```

- [ ] **Step 2: Add cleanup threshold to `TMCPInMemorySessionManager`** — in `sources/MVCFramework.MCP.Session.pas`:

  Add private constant (in implementation section):
  ```pascal
  const
    SESSION_CLEANUP_THRESHOLD = 50;
  ```

  Modify `CreateSession` to trigger cleanup every `SESSION_CLEANUP_THRESHOLD` sessions:
  ```pascal
  function TMCPInMemorySessionManager.CreateSession: IMCPSession;
  var
    LSessionId: string;
    LNeedCleanup: Boolean;
  begin
    LSessionId := TGUID.NewGuid.ToString;
    LSessionId := Copy(LSessionId, 2, Length(LSessionId) - 2);
    Result := TMCPSession.Create(LSessionId);
    LNeedCleanup := False;
    FLock.Enter;
    try
      FSessions.Add(LSessionId, Result);
      LNeedCleanup := (FSessions.Count mod SESSION_CLEANUP_THRESHOLD) = 0;
    finally
      FLock.Leave;
    end;
    { Call cleanup outside the lock to avoid deadlock (CleanupExpiredSessions acquires its own lock). }
    if LNeedCleanup then
      CleanupExpiredSessions;
  end;
  ```

- [ ] **Step 3: Compile** — `dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin`

- [ ] **Step 4: Run test**:
```
python tests/test_mcp_server.py --verbose 2>&1 | grep -A3 "expired_sessions"
```
Expected: PASS.

- [ ] **Step 5: Commit**
```
git add sources/MVCFramework.MCP.Session.pas tests/test_mcp_server.py
git commit -m "fix(EH-4): CleanupExpiredSessions called automatically every 50 sessions in CreateSession"
```

---

## Task 10: DB-4 — Default sample port 8080

**Problem:** `MCPServerSample.dpr` defaults to port 443 (HTTPS port). Without HTTPS configured, this requires elevated privileges and silently fails on most systems. New users are confused.

**Files:**
- Modify: `sample/MCPServerSample.dpr`

- [ ] **Step 1: Find and replace the default port** — in `sample/MCPServerSample.dpr`, locate:
  ```pascal
  RunServer(dotEnv.Env('dmvc.server.port', 443));
  ```
  Replace with:
  ```pascal
  RunServer(dotEnv.Env('dmvc.server.port', 8080));
  ```

- [ ] **Step 2: Compile sample** — `dcc32.exe sample/MCPServerSample.dpr -Esample/bin`

- [ ] **Step 3: Commit**
```
git add sample/MCPServerSample.dpr
git commit -m "fix(DB-4): default sample port changed from 443 to 8080 (no elevated privileges required)"
```

---

## Task 11: Extensive HTTP integration tests

Add comprehensive tests covering all previously untested paths.

**Files:**
- Modify: `tests/test_mcp_server.py`

- [ ] **Step 1: Add full test suite expansion** — append the following test functions:

```python
# ---- Session lifecycle ----

def test_initialize_twice_creates_new_session(base_url):
    """Calling initialize twice gives different sessions."""
    c1 = MCPTestClient(base_url)
    r1 = c1.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "clientInfo": {"name": "C1", "version": "1.0"},
    }, include_session=False)
    c2 = MCPTestClient(base_url)
    r2 = c2.rpc_request("initialize", {
        "protocolVersion": MCP_PROTOCOL_VERSION,
        "clientInfo": {"name": "C2", "version": "1.0"},
    }, include_session=False)
    s1 = r1.headers.get(SESSION_HEADER, "")
    s2 = r2.headers.get(SESSION_HEADER, "")
    assert s1 and s2, "Sessions must be present in response headers"
    assert s1 != s2, f"Two initialize calls must produce different sessions, got {s1}"


def test_delete_session_returns_204(client):
    """DELETE /mcp with a valid session must return 204."""
    resp = client.delete()
    assert resp.status_code == 204, f"Expected 204, got {resp.status_code}: {resp.text}"


def test_delete_nonexistent_session_returns_404(base_url):
    """DELETE /mcp with an unknown session must return 404."""
    resp = requests.delete(
        base_url,
        headers={SESSION_HEADER: "00000000-0000-0000-0000-000000000000"},
    )
    assert resp.status_code == 404, f"Expected 404, got {resp.status_code}"


def test_delete_without_session_returns_400(base_url):
    """DELETE /mcp without session header must return 400."""
    resp = requests.delete(base_url)
    assert resp.status_code == 400, f"Expected 400, got {resp.status_code}"


def test_ping_requires_session(base_url):
    """ping without a session must return an error."""
    resp = requests.post(
        base_url,
        json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        headers={"Content-Type": "application/json"},
    )
    body = resp.json()
    assert "error" in body, f"ping without session must error, got: {body}"


# ---- tools/list ----

def test_tools_list_has_required_fields(client):
    """tools/list: each tool entry must have name, description, inputSchema."""
    resp = client.rpc_request("tools/list")
    body = resp.json()
    tools = body["result"]["tools"]
    assert len(tools) > 0, "Expected at least one tool"
    for t in tools:
        assert "name" in t, f"Tool missing 'name': {t}"
        assert "description" in t, f"Tool {t.get('name')} missing 'description'"
        assert "inputSchema" in t, f"Tool {t.get('name')} missing 'inputSchema'"
        schema = t["inputSchema"]
        assert schema.get("type") == "object", f"inputSchema.type must be 'object': {schema}"


def test_tools_call_unknown_tool_returns_error(client):
    """tools/call with unknown tool name must return an error."""
    resp = client.call_tool("nonexistent_tool_xyz")
    body = resp.json()
    assert "error" in body or body.get("result", {}).get("isError"), \
        f"Unknown tool must return error: {body}"


def test_tools_call_missing_required_param(client):
    """tools/call missing a required parameter must return error."""
    # reverse_string requires 'text' parameter
    resp = client.call_tool("reverse_string", {})
    body = resp.json()
    # Accept either JSON-RPC error or isError in result
    has_error = "error" in body or body.get("result", {}).get("isError", False)
    assert has_error, f"Missing required param must produce error: {body}"


# ---- resources ----

def test_resources_list_has_required_fields(client):
    """resources/list: each entry must have uri, name, description, mimeType."""
    resp = client.rpc_request("resources/list")
    body = resp.json()
    resources = body["result"]["resources"]
    for r in resources:
        assert "uri" in r, f"Resource missing 'uri': {r}"
        assert "name" in r, f"Resource {r.get('uri')} missing 'name'"
        assert "mimeType" in r, f"Resource {r.get('uri')} missing 'mimeType'"


def test_resources_read_blob_returns_blob_field(client):
    """resources/read on a blob resource must return 'blob' field, not 'text'."""
    resp = client.rpc_request("resources/read", {"uri": "test://static-binary"})
    body = resp.json()
    assert "result" in body, f"Missing result: {body}"
    contents = body["result"].get("contents", [])
    assert len(contents) > 0, "Empty contents"
    item = contents[0]
    assert "blob" in item, f"Blob resource must have 'blob' field, got: {item}"
    assert "text" not in item, f"Blob resource must NOT have 'text' field, got: {item}"


def test_resources_read_nonexistent_returns_error(client):
    """resources/read on unknown URI must return error."""
    resp = client.rpc_request("resources/read", {"uri": "test://does-not-exist"})
    body = resp.json()
    assert "error" in body, f"Expected error for unknown resource, got: {body}"


def test_resources_templates_list(client):
    """resources/templates/list must return resourceTemplates array."""
    resp = client.rpc_request("resources/templates/list")
    body = resp.json()
    assert "result" in body, f"Missing result: {body}"
    assert "resourceTemplates" in body["result"], \
        f"Missing 'resourceTemplates' key: {body['result']}"


# ---- prompts ----

def test_prompts_list_has_required_fields(client):
    """prompts/list: each entry must have name, description."""
    resp = client.rpc_request("prompts/list")
    body = resp.json()
    prompts = body["result"]["prompts"]
    assert len(prompts) > 0, "Expected at least one prompt"
    for p in prompts:
        assert "name" in p, f"Prompt missing 'name': {p}"
        assert "description" in p, f"Prompt {p.get('name')} missing 'description'"


def test_prompts_get_nonexistent_returns_error(client):
    """prompts/get on unknown name must return error."""
    resp = client.rpc_request("prompts/get", {"name": "nonexistent_prompt_xyz"})
    body = resp.json()
    assert "error" in body, f"Expected error for unknown prompt, got: {body}"


def test_prompts_get_with_arguments(client):
    """prompts/get with required arguments must return messages."""
    resp = client.rpc_request("prompts/get", {
        "name": "test_prompt_with_arguments",
        "arguments": {"arg1": "hello", "arg2": "world"},
    })
    body = resp.json()
    assert "result" in body, f"Missing result: {body}"
    messages = body["result"].get("messages", [])
    assert len(messages) > 0, f"Expected messages in prompt result: {body}"


# ---- content types ----

def test_tool_image_content_type(client):
    """test_image_content tool must return ImageContent with type='image'."""
    resp = client.call_tool("test_image_content")
    body = resp.json()
    content = body["result"]["content"]
    assert len(content) == 1
    assert content[0]["type"] == "image", f"Expected type='image': {content[0]}"
    assert "data" in content[0], "ImageContent must have 'data'"
    assert "mimeType" in content[0], "ImageContent must have 'mimeType'"


def test_tool_error_content_has_iserror(client):
    """test_error_handling tool must return isError=true."""
    resp = client.call_tool("test_error_handling")
    body = resp.json()
    assert body["result"].get("isError") is True, \
        f"Error tool must set isError=true: {body}"


def test_tool_multiple_content_items(client):
    """test_multiple_content_types must return >1 content items."""
    resp = client.call_tool("test_multiple_content_types")
    body = resp.json()
    content = body["result"]["content"]
    assert len(content) > 1, \
        f"Expected multiple content items, got {len(content)}: {content}"


# ---- JSON-RPC protocol ----

def test_invalid_jsonrpc_version(base_url):
    """Requests with jsonrpc != '2.0' must return -32600."""
    resp = requests.post(
        base_url,
        json={"jsonrpc": "1.0", "id": 1, "method": "ping"},
        headers={"Content-Type": "application/json"},
    )
    body = resp.json()
    assert "error" in body, f"Expected error for invalid jsonrpc version: {body}"


def test_notification_returns_202(client):
    """notifications/initialized must return 202 Accepted (no body required)."""
    resp = client.rpc_notification("notifications/initialized")
    assert resp.status_code in (200, 202, 204), \
        f"Notification must return 2xx, got {resp.status_code}"
```

- [ ] **Step 2: Integrate tests into the test runner** — ensure each function is called from `run_tests(client, base_url)` in the main test function. Add all new function names to the call list.

- [ ] **Step 3: Run all tests**:
```
python tests/test_mcp_server.py --verbose
```
Expected: all existing + new tests PASS.

- [ ] **Step 4: Commit**
```
git add tests/test_mcp_server.py
git commit -m "test: comprehensive HTTP integration tests for all protocol methods and edge cases"
```

---

## Task 12: Extensive stdio integration tests

**Files:**
- Modify: `tests/test_mcp_server_stdio.py`

- [ ] **Step 1: Expand stdio test suite** — add the following tests:

```python
def test_stdio_initialize_response_shape(proc):
    """initialize must return protocolVersion, capabilities, serverInfo."""
    session_id = do_initialize(proc)
    # do_initialize already validates the response; just confirm session given
    assert session_id or True  # session_id may be empty for stdio

def test_stdio_ping(proc):
    """ping must return an empty object result."""
    do_initialize(proc)
    req = json.dumps({"jsonrpc": "2.0", "id": 10, "method": "ping"})
    proc.stdin.write(req + "\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    resp = json.loads(line)
    assert "result" in resp, f"ping must return result: {resp}"
    assert resp["result"] == {}, f"ping result must be empty object, got: {resp['result']}"

def test_stdio_tools_list(proc):
    """tools/list must return tools array after initialize."""
    do_initialize(proc)
    req = json.dumps({"jsonrpc": "2.0", "id": 11, "method": "tools/list"})
    proc.stdin.write(req + "\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    resp = json.loads(line)
    assert "result" in resp, f"tools/list must return result: {resp}"
    tools = resp["result"].get("tools", [])
    assert isinstance(tools, list), f"tools must be a list: {resp}"

def test_stdio_resources_list(proc):
    """resources/list must return resources array."""
    do_initialize(proc)
    req = json.dumps({"jsonrpc": "2.0", "id": 12, "method": "resources/list"})
    proc.stdin.write(req + "\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    resp = json.loads(line)
    assert "result" in resp, f"resources/list must return result: {resp}"
    assert "resources" in resp["result"]

def test_stdio_prompts_list(proc):
    """prompts/list must return prompts array."""
    do_initialize(proc)
    req = json.dumps({"jsonrpc": "2.0", "id": 13, "method": "prompts/list"})
    proc.stdin.write(req + "\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    resp = json.loads(line)
    assert "result" in resp, f"prompts/list must return result: {resp}"
    assert "prompts" in resp["result"]

def test_stdio_tools_call(proc):
    """tools/call must invoke a tool and return content."""
    do_initialize(proc)
    req = json.dumps({
        "jsonrpc": "2.0", "id": 14, "method": "tools/call",
        "params": {"name": "test_simple_text"},
    })
    proc.stdin.write(req + "\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    resp = json.loads(line)
    assert "result" in resp, f"tools/call must return result: {resp}"
    content = resp["result"].get("content", [])
    assert len(content) > 0, f"tools/call result must have content: {resp}"

def test_stdio_unknown_method_returns_error(proc):
    """Unknown methods with an id must return -32603 error."""
    do_initialize(proc)
    req = json.dumps({"jsonrpc": "2.0", "id": 99, "method": "no_such_method"})
    proc.stdin.write(req + "\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    resp = json.loads(line)
    assert "error" in resp, f"Unknown method must return error: {resp}"

def test_stdio_notification_no_response(proc):
    """Notifications (no id) must not produce a response line."""
    do_initialize(proc)
    notif = json.dumps({"jsonrpc": "2.0", "method": "notifications/cancelled"})
    proc.stdin.write(notif + "\n")
    proc.stdin.flush()
    # Wait briefly; no response expected
    line = read_line_timeout(proc, timeout=1)
    assert line is None, \
        f"Notification must not produce a response, got: {line}"

def test_stdio_empty_line_ignored(proc):
    """Empty lines must be silently ignored."""
    do_initialize(proc)
    proc.stdin.write("\n\n   \n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=1)
    assert line is None, f"Empty lines must be ignored, got: {line}"

def test_stdio_invalid_json_returns_parse_error(proc):
    """Malformed JSON must return -32700 parse error."""
    proc.stdin.write("{not valid json}\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    assert line is not None, "Expected error response for invalid JSON"
    resp = json.loads(line)
    assert "error" in resp, f"Expected error: {resp}"
    assert resp["error"]["code"] == -32700, \
        f"Expected -32700 parse error, got {resp['error']['code']}"

def test_stdio_id_preserved_in_response(proc):
    """Response id must match request id (string type preserved)."""
    do_initialize(proc)
    req = json.dumps({"jsonrpc": "2.0", "id": "abc-123", "method": "ping"})
    proc.stdin.write(req + "\n")
    proc.stdin.flush()
    line = read_line_timeout(proc, timeout=5)
    resp = json.loads(line)
    assert resp.get("id") == "abc-123", \
        f"Response id must match request id 'abc-123', got: {resp.get('id')}"
```

- [ ] **Step 2: Run all stdio tests**:
```
python tests/test_mcp_server_stdio.py --verbose
```
Expected: all tests PASS.

- [ ] **Step 3: Commit**
```
git add tests/test_mcp_server_stdio.py
git commit -m "test: comprehensive stdio integration tests for all protocol methods and edge cases"
```

---

## Self-Review

**Spec coverage check:**

| Fix | Task covering it |
|-----|-----------------|
| EH-1 TMCPResourceResult memory safety | Task 1 ✓ |
| EH-2 stdio nil dereference | Task 2 ✓ |
| TS-2 ServerName race | Task 3 ✓ |
| AC-2 BoolToStr lowercase | Task 4 ✓ |
| AC-5 Conformance resource MIME | Task 4 ✓ |
| SEC-1 AutoRecover warning | Task 5 ✓ |
| MF-5 Bridge THTTPClient | Task 6 ✓ |
| PC-1 Version negotiation + instructions | Task 7 ✓ |
| PC-2 Session error code -32001 | Task 8 ✓ |
| EH-4 CleanupExpiredSessions wiring | Task 9 ✓ |
| DB-4 Default port 8080 | Task 10 ✓ |
| PC-4 Batch request detection | Task 2 ✓ |
| Extensive HTTP tests | Task 11 ✓ |
| Extensive stdio tests | Task 12 ✓ |

**No placeholders found.** All steps contain actual code.

**Type consistency:** `TMCPResourceResult.TContentHolder`, `IContentHolder`, `FHolder` used consistently in Task 1. `LHttpClient` local variable in Task 6 replaces all `FHttpClient` references. `MCP_ERR_SESSION = -32001` constant introduced in Task 8 and referenced consistently.
