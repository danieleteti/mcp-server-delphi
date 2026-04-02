# Stdio Transport Support - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add stdio transport to the MCP server so that a single executable can run in HTTP or stdio mode via `--transport stdio|http` command-line switch, with zero impact on provider/business code.

**Architecture:** Extract transport-agnostic request handling from `TMCPEndpoint` into a new `TMCPRequestHandler` class. Create a `TMCPStdioTransport` that reads JSON-RPC from stdin and writes responses to stdout (one JSON object per line, as per MCP stdio spec). `TMCPEndpoint` becomes a thin HTTP adapter that delegates to the handler. The `.dpr` entry point parses `--transport` and launches the appropriate mode.

**Tech Stack:** Delphi 11+, JsonDataObjects, DMVCFramework (HTTP mode only), MCP protocol 2025-03-26

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `sources/MVCFramework.MCP.RequestHandler.pas` | Transport-agnostic JSON-RPC dispatcher + all MCP protocol methods |
| Create | `sources/MVCFramework.MCP.Stdio.pas` | Stdio transport: stdin/stdout loop with JSON-RPC framing |
| Modify | `sources/MVCFramework.MCP.Server.pas` | `TMCPEndpoint` delegates to `TMCPRequestHandler`; remove duplicated logic |
| Modify | `sample/MCPServerSample.dpr` | `--transport stdio\|http` CLI parsing, launch appropriate mode |
| Modify | `tests/testproject/MCPServerUnitTest.dpr` | Same CLI parsing as sample |

---

### Task 1: Create TMCPRequestHandler — transport-agnostic dispatch

This is the core refactoring. All MCP protocol logic moves here, free of any HTTP dependency.

**Files:**
- Create: `sources/MVCFramework.MCP.RequestHandler.pas`

- [ ] **Step 1: Create the unit with the class skeleton**

```pascal
unit MVCFramework.MCP.RequestHandler;

interface

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  JsonDataObjects,
  MVCFramework.MCP.Types, MVCFramework.MCP.Attributes,
  MVCFramework.MCP.ToolProvider, MVCFramework.MCP.ResourceProvider,
  MVCFramework.MCP.PromptProvider, MVCFramework.MCP.Session;

type
  TMCPServer = class; // forward - will be resolved via uses

  { Transport-agnostic MCP request handler.
    Receives a raw JSON-RPC request object, dispatches to the correct
    MCP protocol method, and returns the JSON-RPC response object.
    Notifications return nil (no response expected). }
  TMCPRequestHandler = class
  private
    FServer: TObject; // TMCPServer — forward-declared to avoid circular ref
    FSessionId: string;

    { MCP protocol methods — same signatures as the old TMCPEndpoint }
    function DoInitialize(const AParams: TJDOJsonObject): TJDOJsonObject;
    procedure DoNotificationsInitialized;
    function DoPing: TJDOJsonObject;
    function DoToolsList: TJDOJsonObject;
    function DoToolsCall(const AParams: TJDOJsonObject): TJDOJsonObject;
    function DoResourcesList: TJDOJsonObject;
    function DoResourcesRead(const AParams: TJDOJsonObject): TJDOJsonObject;
    function DoPromptsList: TJDOJsonObject;
    function DoPromptsGet(const AParams: TJDOJsonObject): TJDOJsonObject;
  public
    constructor Create(AServer: TObject);

    { Main entry point. Takes a parsed JSON-RPC request, returns the
      JSON-RPC response (caller owns). Returns nil for notifications. }
    function HandleRequest(const ARequest: TJDOJsonObject): TJDOJsonObject;

    { Validates session for non-initialize methods.
      Raises EMCPSessionError if invalid. Call this from transports that
      manage session externally (HTTP uses header, stdio skips it). }
    procedure ValidateSession(const AMethod: string);

    property SessionId: string read FSessionId write FSessionId;
  end;

  EMCPSessionError = class(Exception);

implementation

uses
  MVCFramework.Logger, MVCFramework.MCP.Server;

{ TMCPRequestHandler }

constructor TMCPRequestHandler.Create(AServer: TObject);
begin
  inherited Create;
  FServer := AServer;
end;

function TMCPRequestHandler.HandleRequest(const ARequest: TJDOJsonObject): TJDOJsonObject;
var
  LMethod: string;
  LParams: TJDOJsonObject;
  LId: Variant;
  LIsNotification: Boolean;
  LResult: TJDOJsonObject;
begin
  LMethod := ARequest.S['method'];
  if ARequest.Contains('params') and (ARequest.Types['params'] = jdtObject) then
    LParams := ARequest.O['params']
  else
    LParams := nil;

  { JSON-RPC: requests have "id", notifications do not }
  LIsNotification := not ARequest.Contains('id');

  { Dispatch to handler }
  LResult := nil;
  if SameText(LMethod, 'initialize') then
    LResult := DoInitialize(LParams)
  else if SameText(LMethod, 'notifications/initialized') then
    DoNotificationsInitialized
  else if SameText(LMethod, 'ping') then
    LResult := DoPing
  else if SameText(LMethod, 'tools/list') then
    LResult := DoToolsList
  else if SameText(LMethod, 'tools/call') then
    LResult := DoToolsCall(LParams)
  else if SameText(LMethod, 'resources/list') then
    LResult := DoResourcesList
  else if SameText(LMethod, 'resources/read') then
    LResult := DoResourcesRead(LParams)
  else if SameText(LMethod, 'prompts/list') then
    LResult := DoPromptsList
  else if SameText(LMethod, 'prompts/get') then
    LResult := DoPromptsGet(LParams)
  else
    raise Exception.CreateFmt('Unknown method: %s', [LMethod]);

  if LIsNotification then
  begin
    LResult.Free; // discard any result for notifications
    Result := nil;
    Exit;
  end;

  { Wrap in JSON-RPC response envelope }
  Result := TJDOJsonObject.Create;
  Result.S['jsonrpc'] := '2.0';
  if LResult <> nil then
    Result.O['result'] := LResult
  else
    Result.O['result'] := TJDOJsonObject.Create;
  { Copy id from request (can be string, integer, or null) }
  case ARequest.Types['id'] of
    jdtString: Result.S['id'] := ARequest.S['id'];
    jdtInt:    Result.I['id'] := ARequest.I['id'];
    jdtLong:   Result.L['id'] := ARequest.L['id'];
    jdtFloat:  Result.F['id'] := ARequest.F['id'];
  else
    Result.S['id'] := ARequest.S['id'];
  end;
end;

procedure TMCPRequestHandler.ValidateSession(const AMethod: string);
var
  LServer: TMCPServer;
begin
  if SameText(AMethod, 'initialize') or
     SameText(AMethod, 'notifications/initialized') then
    Exit;

  LServer := TMCPServer(FServer);
  if FSessionId.IsEmpty or not LServer.SessionManager.SessionExists(FSessionId) then
    raise EMCPSessionError.Create('Invalid or missing session. Send initialize first.');
end;

{ --- MCP protocol methods (extracted from TMCPEndpoint) --- }

function TMCPRequestHandler.DoInitialize(const AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LSession: IMCPSession;
  LClientInfo: TMCPClientInfo;
  LCaps: TMCPCapabilities;
begin
  LServer := TMCPServer(FServer);

  if LServer.ServerName.IsEmpty then
  begin
    LServer.ServerName := 'MCPServer';
    LogW('MCP: ServerName not configured, using default "MCPServer". ' +
      'Set TMCPServer.Instance.ServerName in the .dpr.');
  end;
  if LServer.ServerVersion.IsEmpty then
  begin
    LServer.ServerVersion := '1.0.0';
    LogW('MCP: ServerVersion not configured, using default "1.0.0". ' +
      'Set TMCPServer.Instance.ServerVersion in the .dpr.');
  end;

  LSession := LServer.SessionManager.CreateSession;
  FSessionId := LSession.SessionId;

  if (AParams <> nil) and AParams.Contains('clientInfo') then
    LClientInfo.FromJSON(AParams.O['clientInfo']);
  LSession.ClientInfo := LClientInfo;
  LSession.Initialized := True;

  LogI('MCP: Session created ' + FSessionId +
    ' for client ' + LClientInfo.Name + '/' + LClientInfo.Version);

  LCaps.SupportsTools := LServer.Tools.Count > 0;
  LCaps.SupportsResources := LServer.Resources.Count > 0;
  LCaps.SupportsPrompts := LServer.Prompts.Count > 0;

  Result := TJDOJsonObject.Create;
  Result.S['protocolVersion'] := MCP_PROTOCOL_VERSION;
  Result.O['capabilities'] := LCaps.ToJSON;
  Result.O['serverInfo'].S['name'] := LServer.ServerName;
  Result.O['serverInfo'].S['version'] := LServer.ServerVersion;
end;

procedure TMCPRequestHandler.DoNotificationsInitialized;
begin
  { Notification - nothing to do }
end;

function TMCPRequestHandler.DoPing: TJDOJsonObject;
begin
  Result := TJDOJsonObject.Create;
end;

function TMCPRequestHandler.DoToolsList: TJDOJsonObject;
var
  LServer: TMCPServer;
  LToolsArray: TJDOJsonArray;
  LToolInfo: TMCPToolInfo;
  LToolObj: TJDOJsonObject;
begin
  LServer := TMCPServer(FServer);
  Result := TJDOJsonObject.Create;
  LToolsArray := Result.A['tools'];
  for LToolInfo in LServer.Tools.Values do
  begin
    LToolObj := LToolsArray.AddObject;
    LToolObj.S['name'] := LToolInfo.Name;
    LToolObj.S['description'] := LToolInfo.Description;
    LToolObj.O['inputSchema'] :=
      TJDOJsonObject.Parse(LToolInfo.InputSchema.ToJSON(False)) as TJDOJsonObject;
  end;
end;

function TMCPRequestHandler.DoToolsCall(const AParams: TJDOJsonObject): TJDOJsonObject;

  function FindArgName(const AArguments: TJDOJsonObject; const AParamName: string): string;
  var
    J: Integer;
  begin
    if AArguments <> nil then
      for J := 0 to AArguments.Count - 1 do
        if SameText(AArguments.Names[J], AParamName) then
          Exit(AArguments.Names[J]);
    Result := '';
  end;

var
  LServer: TMCPServer;
  LName: string;
  LArguments: TJDOJsonObject;
  LToolInfo: TMCPToolInfo;
  LProvider: TMCPToolProvider;
  LArgs: TArray<TValue>;
  LToolResult: TMCPToolResult;
  I: Integer;
  LArgKey: string;
begin
  LServer := TMCPServer(FServer);

  if AParams = nil then
    raise Exception.Create('Missing params for tools/call');
  LName := AParams.S['name'];
  if LName.IsEmpty then
    raise Exception.Create('Missing tool name');

  if AParams.Contains('arguments') and (AParams.Types['arguments'] = jdtObject) then
    LArguments := AParams.O['arguments']
  else
    LArguments := nil;

  if not LServer.Tools.TryGetValue(LowerCase(LName), LToolInfo) then
    raise Exception.CreateFmt('Tool not found: %s', [LName]);

  { Validate required params }
  for I := 0 to High(LToolInfo.Params) do
  begin
    if LToolInfo.Params[I].Required and
       (FindArgName(LArguments, LToolInfo.Params[I].Name) = '') then
      raise Exception.CreateFmt('Missing required parameter: %s',
        [LToolInfo.Params[I].Name]);
  end;

  { Build TValue array }
  SetLength(LArgs, Length(LToolInfo.Params));
  for I := 0 to High(LToolInfo.Params) do
  begin
    LArgKey := FindArgName(LArguments, LToolInfo.Params[I].Name);
    if LArgKey <> '' then
    begin
      case LToolInfo.Params[I].TypeKind of
        tkUString, tkString, tkLString, tkWString:
          LArgs[I] := TValue.From<string>(LArguments.S[LArgKey]);
        tkInteger:
          LArgs[I] := TValue.From<Integer>(LArguments.I[LArgKey]);
        tkInt64:
          LArgs[I] := TValue.From<Int64>(LArguments.L[LArgKey]);
        tkFloat:
          LArgs[I] := TValue.From<Double>(LArguments.F[LArgKey]);
        tkEnumeration:
          LArgs[I] := TValue.From<Boolean>(LArguments.B[LArgKey]);
      else
        raise Exception.CreateFmt('Unsupported parameter type for "%s"',
          [LToolInfo.Params[I].Name]);
      end;
    end
    else
    begin
      case LToolInfo.Params[I].TypeKind of
        tkUString, tkString, tkLString, tkWString:
          LArgs[I] := TValue.From<string>('');
        tkInteger:
          LArgs[I] := TValue.From<Integer>(0);
        tkInt64:
          LArgs[I] := TValue.From<Int64>(0);
        tkFloat:
          LArgs[I] := TValue.From<Double>(0.0);
        tkEnumeration:
          LArgs[I] := TValue.From<Boolean>(False);
      else
        LArgs[I] := TValue.Empty;
      end;
    end;
  end;

  LProvider := LToolInfo.ProviderClass.Create;
  try
    LToolResult := LToolInfo.RttiMethod.Invoke(LProvider, LArgs).AsType<TMCPToolResult>;
    Result := LToolResult.ToJSON;
  finally
    LProvider.Free;
  end;
end;

function TMCPRequestHandler.DoResourcesList: TJDOJsonObject;
var
  LServer: TMCPServer;
  LResArray: TJDOJsonArray;
  LInfo: TMCPResourceInfo;
  LResObj: TJDOJsonObject;
begin
  LServer := TMCPServer(FServer);
  Result := TJDOJsonObject.Create;
  LResArray := Result.A['resources'];
  for LInfo in LServer.Resources.Values do
  begin
    LResObj := LResArray.AddObject;
    LResObj.S['uri'] := LInfo.URI;
    LResObj.S['name'] := LInfo.Name;
    LResObj.S['description'] := LInfo.Description;
    LResObj.S['mimeType'] := LInfo.MimeType;
  end;
end;

function TMCPRequestHandler.DoResourcesRead(const AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LURI: string;
  LInfo: TMCPResourceInfo;
  LProvider: TMCPResourceProvider;
  LResResult: TMCPResourceResult;
begin
  LServer := TMCPServer(FServer);

  if AParams = nil then
    raise Exception.Create('Missing params for resources/read');
  LURI := AParams.S['uri'];
  if LURI.IsEmpty then
    raise Exception.Create('Missing resource URI');

  if not LServer.Resources.TryGetValue(LowerCase(LURI), LInfo) then
    raise Exception.Create('Resource not found: ' + LURI);

  LProvider := LInfo.ProviderClass.Create;
  try
    LResResult := LInfo.RttiMethod.Invoke(LProvider,
      [TValue.From<string>(LURI)]).AsType<TMCPResourceResult>;
    Result := LResResult.ToJSON;
  finally
    LProvider.Free;
  end;
end;

function TMCPRequestHandler.DoPromptsList: TJDOJsonObject;
var
  LServer: TMCPServer;
  LPromptsArray: TJDOJsonArray;
  LInfo: TMCPPromptInfo;
  LPromptObj: TJDOJsonObject;
  LArgsArray: TJDOJsonArray;
  LArgObj: TJDOJsonObject;
  I: Integer;
begin
  LServer := TMCPServer(FServer);
  Result := TJDOJsonObject.Create;
  LPromptsArray := Result.A['prompts'];
  for LInfo in LServer.Prompts.Values do
  begin
    LPromptObj := LPromptsArray.AddObject;
    LPromptObj.S['name'] := LInfo.Name;
    LPromptObj.S['description'] := LInfo.Description;
    if Length(LInfo.Args) > 0 then
    begin
      LArgsArray := LPromptObj.A['arguments'];
      for I := 0 to High(LInfo.Args) do
      begin
        LArgObj := LArgsArray.AddObject;
        LArgObj.S['name'] := LInfo.Args[I].Name;
        LArgObj.S['description'] := LInfo.Args[I].Description;
        LArgObj.B['required'] := LInfo.Args[I].Required;
      end;
    end;
  end;
end;

function TMCPRequestHandler.DoPromptsGet(const AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LName: string;
  LArguments: TJDOJsonObject;
  LInfo: TMCPPromptInfo;
  LProvider: TMCPPromptProvider;
  LPromptResult: TMCPPromptResult;
begin
  LServer := TMCPServer(FServer);

  if AParams = nil then
    raise Exception.Create('Missing params for prompts/get');
  LName := AParams.S['name'];
  if LName.IsEmpty then
    raise Exception.Create('Missing prompt name');

  if not LServer.Prompts.TryGetValue(LowerCase(LName), LInfo) then
    raise Exception.Create('Prompt not found: ' + LName);

  if AParams.Contains('arguments') and (AParams.Types['arguments'] = jdtObject) then
    LArguments := AParams.O['arguments']
  else
    LArguments := TJDOJsonObject.Create;

  try
    LProvider := LInfo.ProviderClass.Create;
    try
      LPromptResult := LInfo.RttiMethod.Invoke(LProvider,
        [TValue.From<TJDOJsonObject>(LArguments)]).AsType<TMCPPromptResult>;
      Result := LPromptResult.ToJSON;
    finally
      LProvider.Free;
    end;
  finally
    if not AParams.Contains('arguments') then
      LArguments.Free;
  end;
end;

end.
```

- [ ] **Step 2: Verify the file compiles**

Add the unit to a `.dpr` uses clause and compile. Expect compilation success. If there are circular reference issues between `MVCFramework.MCP.RequestHandler` and `MVCFramework.MCP.Server`, the `uses MVCFramework.MCP.Server` is in the implementation section which avoids the cycle.

- [ ] **Step 3: Commit**

```bash
git add sources/MVCFramework.MCP.RequestHandler.pas
git commit -m "feat: extract TMCPRequestHandler for transport-agnostic MCP dispatch"
```

---

### Task 2: Refactor TMCPEndpoint to delegate to TMCPRequestHandler

`TMCPEndpoint` becomes a thin HTTP adapter. All protocol logic is delegated to `TMCPRequestHandler`.

**Files:**
- Modify: `sources/MVCFramework.MCP.Server.pas`

- [ ] **Step 1: Add TMCPRequestHandler to the uses clause**

In `MVCFramework.MCP.Server.pas`, add `MVCFramework.MCP.RequestHandler` to the implementation `uses`:

```pascal
implementation

uses
  MVCFramework.Logger, MVCFramework.MCP.RequestHandler;
```

- [ ] **Step 2: Add FHandler field to TMCPEndpoint**

In the `TMCPEndpoint` class declaration, add a private field:

```pascal
  TMCPEndpoint = class
  private
    FServer: TMCPServer;
    FSessionId: string;
    FHandler: TMCPRequestHandler;
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;
    // ... rest stays the same
  end;
```

- [ ] **Step 3: Rewrite TMCPEndpoint constructor and add destructor**

```pascal
constructor TMCPEndpoint.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
  FHandler := TMCPRequestHandler.Create(AServer);
end;

destructor TMCPEndpoint.Destroy;
begin
  FHandler.Free;
  inherited;
end;
```

- [ ] **Step 4: Simplify TMCPEndpoint method bodies to delegate to FHandler**

Replace the body of each protocol method. The methods keep their DMVCFramework JSON-RPC signatures (required for `PublishObject` dispatch) but delegate internally. Example for `Initialize`:

```pascal
function TMCPEndpoint.Initialize(const ProtocolVersion: string;
  const Capabilities: TJDOJsonObject; const ClientInfo: TJDOJsonObject;
  const ExtraParams: TJDOJsonArray): TJDOJsonObject;
var
  LParams: TJDOJsonObject;
begin
  LParams := TJDOJsonObject.Create;
  try
    LParams.S['protocolVersion'] := ProtocolVersion;
    if Capabilities <> nil then
      LParams.O['capabilities'] := TJDOJsonObject.Parse(Capabilities.ToJSON(False)) as TJDOJsonObject;
    if ClientInfo <> nil then
      LParams.O['clientInfo'] := TJDOJsonObject.Parse(ClientInfo.ToJSON(False)) as TJDOJsonObject;
    Result := FHandler.DoInitialize(LParams);
    FSessionId := FHandler.SessionId;
  finally
    LParams.Free;
  end;
end;
```

For simpler methods, delegation is trivial:

```pascal
procedure TMCPEndpoint.NotificationsInitialized;
begin
  FHandler.DoNotificationsInitialized;
end;

function TMCPEndpoint.Ping: TJDOJsonObject;
begin
  Result := FHandler.DoPing;
end;

function TMCPEndpoint.ToolsList: TJDOJsonObject;
begin
  Result := FHandler.DoToolsList;
end;

function TMCPEndpoint.ToolsCall(const Name: string; const Arguments: TJDOJsonObject;
  const ExtraParams: TJDOJsonArray): TJDOJsonObject;
var
  LParams: TJDOJsonObject;
begin
  LParams := TJDOJsonObject.Create;
  try
    LParams.S['name'] := Name;
    if Arguments <> nil then
      LParams.O['arguments'] := TJDOJsonObject.Parse(Arguments.ToJSON(False)) as TJDOJsonObject;
    Result := FHandler.DoToolsCall(LParams);
  finally
    LParams.Free;
  end;
end;

function TMCPEndpoint.ResourcesList: TJDOJsonObject;
begin
  Result := FHandler.DoResourcesList;
end;

function TMCPEndpoint.ResourcesRead(const URI: string;
  const ExtraParams: TJDOJsonArray): TJDOJsonObject;
var
  LParams: TJDOJsonObject;
begin
  LParams := TJDOJsonObject.Create;
  try
    LParams.S['uri'] := URI;
    Result := FHandler.DoResourcesRead(LParams);
  finally
    LParams.Free;
  end;
end;

function TMCPEndpoint.PromptsList: TJDOJsonObject;
begin
  Result := FHandler.DoPromptsList;
end;

function TMCPEndpoint.PromptsGet(const Name: string; const Arguments: TJDOJsonObject;
  const ExtraParams: TJDOJsonArray): TJDOJsonObject;
var
  LParams: TJDOJsonObject;
begin
  LParams := TJDOJsonObject.Create;
  try
    LParams.S['name'] := Name;
    if Arguments <> nil then
      LParams.O['arguments'] := TJDOJsonObject.Parse(Arguments.ToJSON(False)) as TJDOJsonObject;
    Result := FHandler.DoPromptsGet(LParams);
  finally
    LParams.Free;
  end;
end;
```

- [ ] **Step 5: Update OnBeforeRoutingHook to use handler for session validation**

```pascal
procedure TMCPEndpoint.OnBeforeRoutingHook(const Context: TWebContext; const JSON: TJDOJsonObject);
var
  LMethod: string;
begin
  LMethod := JSON.S[JSONRPC_METHOD];
  JSON.S[JSONRPC_METHOD] := LMethod.Replace('/', '');

  if not SameText(LMethod, 'initialize') and
     not SameText(LMethod, 'notifications/initialized') then
  begin
    FSessionId := Context.Request.Headers[MCP_SESSION_HEADER];
    FHandler.SessionId := FSessionId;
    FHandler.ValidateSession(LMethod);
  end;
end;
```

Note: `OnAfterCallHook` remains unchanged — it handles HTTP-specific header/status code concerns.

- [ ] **Step 6: Make Do* methods public in TMCPRequestHandler**

The `Do*` methods in `TMCPRequestHandler` must be `public` (not `private`) so that `TMCPEndpoint` can call them directly. Update the class declaration in `MVCFramework.MCP.RequestHandler.pas` accordingly — move all `Do*` methods from `private` to `public`.

- [ ] **Step 7: Verify HTTP mode still works**

Build the sample project and test with an MCP client (e.g. MCP Inspector) over HTTP. All existing functionality must work identically.

- [ ] **Step 8: Commit**

```bash
git add sources/MVCFramework.MCP.Server.pas sources/MVCFramework.MCP.RequestHandler.pas
git commit -m "refactor: TMCPEndpoint delegates to TMCPRequestHandler"
```

---

### Task 3: Create TMCPStdioTransport

Implements the MCP stdio transport: reads JSON-RPC messages from stdin (one per line), dispatches via `TMCPRequestHandler`, writes JSON-RPC responses to stdout.

**Files:**
- Create: `sources/MVCFramework.MCP.Stdio.pas`

- [ ] **Step 1: Create the unit**

```pascal
unit MVCFramework.MCP.Stdio;

interface

uses
  MVCFramework.MCP.RequestHandler;

type
  { MCP stdio transport.
    Reads JSON-RPC messages from stdin (one JSON object per line),
    dispatches to TMCPRequestHandler, writes responses to stdout.
    Logs go to stderr as per MCP spec.

    Ref: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#stdio }
  TMCPStdioTransport = class
  private
    FHandler: TMCPRequestHandler;
    procedure LogStderr(const AMessage: string);
  public
    constructor Create(AServer: TObject);
    destructor Destroy; override;
    { Runs the stdin/stdout loop. Blocks until stdin is closed (EOF). }
    procedure Run;
  end;

implementation

uses
  System.SysUtils, System.Classes, JsonDataObjects,
  MVCFramework.MCP.Server;

constructor TMCPStdioTransport.Create(AServer: TObject);
begin
  inherited Create;
  FHandler := TMCPRequestHandler.Create(AServer);
end;

destructor TMCPStdioTransport.Destroy;
begin
  FHandler.Free;
  inherited;
end;

procedure TMCPStdioTransport.LogStderr(const AMessage: string);
begin
  { MCP spec: servers MAY write UTF-8 strings to stderr for logging.
    Must never write to stdout except JSON-RPC messages. }
  System.Write(ErrOutput, AMessage + sLineBreak);
end;

procedure TMCPStdioTransport.Run;
var
  LLine: string;
  LRequest, LResponse, LErrorResp: TJDOJsonObject;
begin
  LogStderr('MCP stdio transport started. Reading from stdin...');

  while not EOF(Input) do
  begin
    ReadLn(Input, LLine);
    LLine := LLine.Trim;
    if LLine.IsEmpty then
      Continue;

    LRequest := nil;
    LResponse := nil;
    try
      try
        LRequest := TJDOJsonObject.Parse(LLine) as TJDOJsonObject;
      except
        on E: Exception do
        begin
          { JSON parse error — send JSON-RPC error response }
          LErrorResp := TJDOJsonObject.Create;
          try
            LErrorResp.S['jsonrpc'] := '2.0';
            LErrorResp.O['error'].I['code'] := -32700;
            LErrorResp.O['error'].S['message'] := 'Parse error: ' + E.Message;
            LErrorResp.S['id'] := 'null';
            WriteLn(Output, LErrorResp.ToJSON(True));
            Flush(Output);
          finally
            LErrorResp.Free;
          end;
          Continue;
        end;
      end;

      try
        { Session validation: for stdio, session is managed implicitly.
          After initialize, we store the session id and set it on every request. }
        FHandler.ValidateSession(LRequest.S['method']);
        LResponse := FHandler.HandleRequest(LRequest);
      except
        on E: EMCPSessionError do
        begin
          if LRequest.Contains('id') then
          begin
            LErrorResp := TJDOJsonObject.Create;
            try
              LErrorResp.S['jsonrpc'] := '2.0';
              LErrorResp.O['error'].I['code'] := -32600;
              LErrorResp.O['error'].S['message'] := E.Message;
              case LRequest.Types['id'] of
                jdtString: LErrorResp.S['id'] := LRequest.S['id'];
                jdtInt:    LErrorResp.I['id'] := LRequest.I['id'];
                jdtLong:   LErrorResp.L['id'] := LRequest.L['id'];
              else
                LErrorResp.S['id'] := LRequest.S['id'];
              end;
              WriteLn(Output, LErrorResp.ToJSON(True));
              Flush(Output);
            finally
              LErrorResp.Free;
            end;
          end;
          Continue;
        end;
        on E: Exception do
        begin
          if LRequest.Contains('id') then
          begin
            LErrorResp := TJDOJsonObject.Create;
            try
              LErrorResp.S['jsonrpc'] := '2.0';
              LErrorResp.O['error'].I['code'] := -32603;
              LErrorResp.O['error'].S['message'] := E.Message;
              case LRequest.Types['id'] of
                jdtString: LErrorResp.S['id'] := LRequest.S['id'];
                jdtInt:    LErrorResp.I['id'] := LRequest.I['id'];
                jdtLong:   LErrorResp.L['id'] := LRequest.L['id'];
              else
                LErrorResp.S['id'] := LRequest.S['id'];
              end;
              WriteLn(Output, LErrorResp.ToJSON(True));
              Flush(Output);
            finally
              LErrorResp.Free;
            end;
          end
          else
            LogStderr('Error processing notification: ' + E.Message);
          Continue;
        end;
      end;

      { Write response (nil means notification — no response) }
      if LResponse <> nil then
      begin
        WriteLn(Output, LResponse.ToJSON(True));
        Flush(Output);
      end;
    finally
      LResponse.Free;
      LRequest.Free;
    end;
  end;

  LogStderr('MCP stdio transport: stdin closed, shutting down.');
end;

end.
```

Key design points:
- `ToJSON(True)` produces compact single-line JSON (no indentation) — one message per line as MCP spec requires.
- `Flush(Output)` after every write ensures the client receives the response immediately.
- Errors are returned as JSON-RPC error objects with standard error codes (-32700 parse error, -32600 invalid request, -32603 internal error).
- Notifications (no `id`) never get a response, even on error — logged to stderr instead.

- [ ] **Step 2: Commit**

```bash
git add sources/MVCFramework.MCP.Stdio.pas
git commit -m "feat: add TMCPStdioTransport for MCP stdio transport"
```

---

### Task 4: Add --transport CLI switch to the sample application

**Files:**
- Modify: `sample/MCPServerSample.dpr`

- [ ] **Step 1: Add MVCFramework.MCP.Stdio to uses clause**

```pascal
uses
  System.SysUtils,
  Web.ReqMulti,
  Web.WebReq,
  Web.WebBroker,
  MVCFramework,
  MVCFramework.Logger,
  MVCFramework.DotEnv,
  MVCFramework.Commons,
  MVCFramework.Serializer.Commons,
  IdContext,
  IdHTTPWebBrokerBridge,
  TaurusTLS,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Stdio,       // <-- add
  MVCFramework.Signal,
  MyToolsU in 'MyToolsU.pas',
  WebModuleU in 'WebModuleU.pas' {MyWebModule: TWebModule};
```

- [ ] **Step 2: Add RunStdio procedure and ParseTransport function**

Add these before the `begin` block, after `RunServer`:

```pascal
procedure RunStdio;
var
  LTransport: TMCPStdioTransport;
begin
  LTransport := TMCPStdioTransport.Create(TMCPServer.Instance);
  try
    LTransport.Run;
  finally
    LTransport.Free;
  end;
end;

function ParseTransport: string;
var
  I: Integer;
begin
  Result := 'http'; // default
  for I := 1 to ParamCount do
  begin
    if SameText(ParamStr(I), '--transport') and (I < ParamCount) then
    begin
      Result := LowerCase(ParamStr(I + 1));
      Exit;
    end;
    { Also support --transport=stdio syntax }
    if ParamStr(I).StartsWith('--transport=', True) then
    begin
      Result := LowerCase(Copy(ParamStr(I), Length('--transport=') + 1, MaxInt));
      Exit;
    end;
  end;
end;
```

- [ ] **Step 3: Modify the main block to use ParseTransport**

Replace the `begin..end.` block:

```pascal
var
  LTransport: string;
begin
  { Enable ReportMemoryLeaksOnShutdown during debug }
  // ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;

  MVCSerializeNulls := True;
  MVCNameCaseDefault := TMVCNameCase.ncCamelCase;
  UseConsoleLogger := True;
  UseLoggerVerbosityLevel := TLogLevel.levNormal;

  TMCPServer.Instance.ServerName := 'DMVCFrameworkMCPServerSample';
  TMCPServer.Instance.ServerVersion := '1.0.0';

  LTransport := ParseTransport;

  if LTransport = 'stdio' then
  begin
    { Stdio mode: disable console logger (stdout is reserved for JSON-RPC) }
    UseConsoleLogger := False;
    try
      RunStdio;
    except
      on E: Exception do
        System.Write(ErrOutput, E.ClassName + ': ' + E.Message + sLineBreak);
    end;
  end
  else if LTransport = 'http' then
  begin
    LogI('** MCP Server Sample ** powered by DMVCFramework build ' + DMVCFRAMEWORK_VERSION);
    try
      if WebRequestHandler <> nil then
        WebRequestHandler.WebModuleClass := WebModuleClass;
      WebRequestHandlerProc.MaxConnections := dotEnv.Env('dmvc.handler.max_connections', 1024);
      RunServer(dotEnv.Env('dmvc.server.port', 443));
    except
      on E: Exception do
        LogF(E.ClassName + ': ' + E.Message);
    end;
  end
  else
  begin
    WriteLn(ErrOutput, 'Unknown transport: ' + LTransport);
    WriteLn(ErrOutput, 'Usage: MCPServerSample [--transport http|stdio]');
    ExitCode := 1;
  end;
end.
```

Key points:
- `--transport stdio` disables `UseConsoleLogger` to prevent log output on stdout (MCP spec: stdout is exclusively for JSON-RPC messages).
- Errors in stdio mode go to stderr.
- Default is `http` for backward compatibility.

- [ ] **Step 4: Commit**

```bash
git add sample/MCPServerSample.dpr
git commit -m "feat: add --transport stdio|http CLI switch to sample app"
```

---

### Task 5: Add --transport CLI switch to the test server

Same pattern as Task 4, applied to the test server.

**Files:**
- Modify: `tests/testproject/MCPServerUnitTest.dpr`

- [ ] **Step 1: Add MVCFramework.MCP.Stdio to uses clause**

Add `MVCFramework.MCP.Stdio,` after `MVCFramework.MCP.Server,` in the uses clause.

- [ ] **Step 2: Add RunStdio and ParseTransport (identical to Task 4)**

Add the same `RunStdio` procedure and `ParseTransport` function before the main `begin..end.` block.

- [ ] **Step 3: Modify the main block**

Same pattern as Task 4 Step 3, but using the test server's existing configuration:

```pascal
var
  LTransport: string;
begin
  ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;

  MVCSerializeNulls := True;
  MVCNameCaseDefault := TMVCNameCase.ncCamelCase;
  UseConsoleLogger := True;
  UseLoggerVerbosityLevel := TLogLevel.levNormal;

  TMCPServer.Instance.ServerName := 'MCPServerUnitTest';
  TMCPServer.Instance.ServerVersion := '1.0.0';

  LTransport := ParseTransport;

  if LTransport = 'stdio' then
  begin
    UseConsoleLogger := False;
    try
      RunStdio;
    except
      on E: Exception do
        System.Write(ErrOutput, E.ClassName + ': ' + E.Message + sLineBreak);
    end;
  end
  else if LTransport = 'http' then
  begin
    LogI('** MCP Server Unit Test ** powered by DMVCFramework build ' + DMVCFRAMEWORK_VERSION);
    try
      if WebRequestHandler <> nil then
        WebRequestHandler.WebModuleClass := WebModuleClass;
      WebRequestHandlerProc.MaxConnections := dotEnv.Env('dmvc.handler.max_connections', 1024);
      RunServer(dotEnv.Env('dmvc.server.port', 8080));
    except
      on E: Exception do
        LogF(E.ClassName + ': ' + E.Message);
    end;
  end
  else
  begin
    WriteLn(ErrOutput, 'Unknown transport: ' + LTransport);
    WriteLn(ErrOutput, 'Usage: MCPServerUnitTest [--transport http|stdio]');
    ExitCode := 1;
  end;
end.
```

- [ ] **Step 4: Commit**

```bash
git add tests/testproject/MCPServerUnitTest.dpr
git commit -m "feat: add --transport stdio|http CLI switch to test server"
```

---

### Task 6: Manual integration test of stdio transport

**Files:** none (testing only)

- [ ] **Step 1: Build the sample app**

```bash
dcc32.exe Sample/MCPServerSample.dpr -ESample/bin
```

Expected: compiles successfully.

- [ ] **Step 2: Test stdio with piped JSON-RPC initialize request**

Create a test input file `test_stdio.jsonl`:

```json
{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"test","version":"0.1"}},"id":1}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{"message":"hello from stdio"}},"id":3}
{"jsonrpc":"2.0","method":"ping","id":4}
```

Run:

```bash
cat test_stdio.jsonl | Sample/bin/MCPServerSample.exe --transport stdio
```

Expected output (one JSON-RPC response per line, no responses for notifications):

```
{"jsonrpc":"2.0","result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"DMVCFrameworkMCPServerSample","version":"1.0.0"}},"id":1}
{"jsonrpc":"2.0","result":{"tools":[{"name":"reverse_string",...},{"name":"string_length",...},{"name":"echo",...}]},"id":2}
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"hello from stdio"}]},"id":3}
{"jsonrpc":"2.0","result":{},"id":4}
```

Verify:
- 4 response lines (no response for `notifications/initialized`)
- `initialize` returns protocol version and capabilities
- `tools/list` returns 3 tools
- `tools/call` returns the echoed message
- `ping` returns empty result
- No log output on stdout (logs go to stderr only)

- [ ] **Step 3: Test error handling**

```bash
echo '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}' | Sample/bin/MCPServerSample.exe --transport stdio
```

Expected: JSON-RPC error response with "Invalid or missing session" because `initialize` was not called first.

- [ ] **Step 4: Verify HTTP mode is unchanged**

```bash
Sample/bin/MCPServerSample.exe
```

Expected: starts the HTTP server on the configured port, identical behavior to before.

---

## Architecture Summary

```
                    +-----------------------+
                    |    Provider Layer     |
                    | (transport-agnostic)  |
                    |                       |
                    | TMCPToolProvider      |
                    | TMCPResourceProvider  |
                    | TMCPPromptProvider    |
                    +-----------+-----------+
                                |
                    +-----------+-----------+
                    |   TMCPRequestHandler  |  <-- NEW: all MCP dispatch logic
                    | (transport-agnostic)  |
                    +-----------+-----------+
                           /           \
              +-----------+--+   +-----+-----------+
              | TMCPEndpoint |   | TMCPStdioTransport|  <-- NEW
              | (HTTP adapter)|   | (stdio adapter)  |
              |  via DMVC    |   |  stdin/stdout    |
              |  PublishObj  |   |  JSON-RPC loop   |
              +--------------+   +------------------+
                    |                    |
              HTTP POST /mcp       stdin/stdout
```

**Zero impact on business code:** `MyToolsU.pas`, `MCPTestToolsU.pas`, and all provider classes remain completely unchanged. They only depend on `TMCPToolProvider`, `TMCPToolResult`, and `MCPTool`/`MCPParam` attributes — none of which know about transports.
