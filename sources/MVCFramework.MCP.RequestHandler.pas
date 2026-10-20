// ***************************************************************************
//
// MCP Server Library for DMVCFramework
//
// Copyright (c) 2010-2026 Daniele Teti
//
// https://github.com/danieleteti/delphimvcframework
//
// ***************************************************************************
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// ***************************************************************************

unit MVCFramework.MCP.RequestHandler;

interface

uses
  System.SysUtils, System.Rtti, System.RegularExpressions,
  JsonDataObjects, MVCFramework.MCP.Types;

type
  EMCPSessionError = class(Exception);
  EMCPInvalidRequest = class(Exception);

  { A protocol-level failure with its JSON-RPC code. HTTPStatus is the status the
    Streamable HTTP transport must answer with (0 = leave the transport default).
    Data, when set, is the JSON-RPC error "data" member; the exception owns it. }
  EMCPProtocolError = class(Exception)
  private
    FCode: Integer;
    FHTTPStatus: Integer;
    FData: TJDOJsonObject;
  public
    constructor Create(ACode, AHTTPStatus: Integer; const AMessage: string;
      AData: TJDOJsonObject = nil);
    destructor Destroy; override;
    property Code: Integer read FCode;
    property HTTPStatus: Integer read FHTTPStatus;
    property Data: TJDOJsonObject read FData;
  end;

  { -----------------------------------------------------------------------
    TMCPRequestHandler - transport-agnostic MCP protocol dispatch.
    Encapsulates all MCP method handling without any HTTP dependency.
    Used by both TMCPEndpoint (HTTP) and TMCPStdioTransport (stdio).
    ----------------------------------------------------------------------- }
  TMCPRequestHandler = class
  private
    FServer: TObject;  { Actually TMCPServer; typed as TObject to avoid circular reference }
    FSessionId: string;
    FCaller: TMCPCaller;
    FModern: Boolean;
    function ListCacheScope: string;
  public
    constructor Create(AServer: TObject);

    { Main entry point: dispatches a parsed JSON-RPC request and returns
      the JSON-RPC response. Returns nil for notifications (no id). }
    function HandleRequest(ARequest: TJDOJsonObject): TJDOJsonObject;

    { Session validation: raises EMCPSessionError for non-initialize
      methods when the session is missing or invalid. Legacy era only. }
    procedure ValidateSession(const AMethod: string);

    { Decides which era the request speaks and validates it.
      Modern (params._meta carries io.modelcontextprotocol/protocolVersion):
      the version must be supported and clientCapabilities must be present,
      otherwise EMCPProtocolError; no session is looked at. Legacy (no such
      key): ValidateSession. AParams may be nil. After the call Modern says
      which era this request is in. }
    procedure PrepareRequest(const AMethod: string; AParams: TJDOJsonObject);

    { Modern era only: adds resultType, the serverInfo in _meta and, for the
      cacheable results, ttlMs and cacheScope. Safe to call on any result. }
    procedure DecorateResult(const AMethod: string; AResult: TJDOJsonObject);

    { server/discover (modern era, but answered in both). }
    function DoServerDiscover: TJDOJsonObject;

    { Individual MCP method handlers - public so transports can call them directly }
    function DoInitialize(AParams: TJDOJsonObject): TJDOJsonObject;
    procedure DoNotificationsInitialized;
    function DoPing: TJDOJsonObject;
    function DoToolsList: TJDOJsonObject;
    function DoToolsCall(AParams: TJDOJsonObject): TJDOJsonObject;
    function DoResourcesList: TJDOJsonObject;
    function DoResourcesTemplatesList: TJDOJsonObject;
    function DoResourcesRead(AParams: TJDOJsonObject): TJDOJsonObject;
    function DoPromptsList: TJDOJsonObject;
    function DoPromptsGet(AParams: TJDOJsonObject): TJDOJsonObject;

    property SessionId: string read FSessionId write FSessionId;
    property Caller: TMCPCaller read FCaller write FCaller;
    property Modern: Boolean read FModern;
  end;

implementation

uses
  System.TypInfo, System.Generics.Collections, System.Generics.Defaults,
  MVCFramework.Logger,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.ToolProvider,
  MVCFramework.MCP.ResourceProvider,
  MVCFramework.MCP.PromptProvider,
  MVCFramework.MCP.Session;

{ EMCPProtocolError }

constructor EMCPProtocolError.Create(ACode, AHTTPStatus: Integer;
  const AMessage: string; AData: TJDOJsonObject);
begin
  inherited Create(AMessage);
  FCode := ACode;
  FHTTPStatus := AHTTPStatus;
  FData := AData;
end;

destructor EMCPProtocolError.Destroy;
begin
  FData.Free;
  inherited;
end;

{ TMCPRequestHandler }

constructor TMCPRequestHandler.Create(AServer: TObject);
begin
  inherited Create;
  FServer := AServer;
end;

procedure TMCPRequestHandler.PrepareRequest(const AMethod: string;
  AParams: TJDOJsonObject);
var
  LMeta: TJDOJsonObject;
  LData: TJDOJsonObject;
begin
  FModern := False;

  { The handshake methods belong to the legacy era whatever else the request carries. }
  if SameText(AMethod, 'initialize') or
     SameText(AMethod, 'notifications/initialized') then
    Exit;

  if (AParams <> nil) and AParams.Contains('_meta') and
     (AParams.Types['_meta'] = jdtObject) and
     AParams.O['_meta'].Contains(MCP_META_PROTOCOL_VERSION) then
  begin
    LMeta := AParams.O['_meta'];
    if LMeta.S[MCP_META_PROTOCOL_VERSION] <> MCP_PROTOCOL_VERSION_MODERN then
    begin
      LData := TJDOJsonObject.Create;
      LData.A['supported'].Add(MCP_PROTOCOL_VERSION_MODERN);
      LData.A['supported'].Add(MCP_PROTOCOL_VERSION);
      LData.S['requested'] := LMeta.S[MCP_META_PROTOCOL_VERSION];
      raise EMCPProtocolError.Create(MCP_ERR_UNSUPPORTED_VERSION, 400,
        'Unsupported protocol version', LData);
    end;
    if not (LMeta.Contains(MCP_META_CLIENT_CAPABILITIES) and
            (LMeta.Types[MCP_META_CLIENT_CAPABILITIES] = jdtObject)) then
      raise EMCPProtocolError.Create(-32602, 400,
        'Invalid params: _meta.' + MCP_META_CLIENT_CAPABILITIES + ' is required');
    FModern := True;
    Exit;
  end;

  { No version in _meta: a legacy-era request, session rules apply. This
    includes a server/discover without _meta, which is not a valid modern
    request; the session error is what tells a client probing for the
    modern era that it must fall back to initialize. }
  ValidateSession(AMethod);
end;

function TMCPRequestHandler.ListCacheScope: string;
begin
  { What a list contains may depend on who asks (an authenticated caller):
    shared caches must not keep it. }
  if FCaller.UserName.IsEmpty then
    Result := 'public'
  else
    Result := 'private';
end;

procedure TMCPRequestHandler.DecorateResult(const AMethod: string;
  AResult: TJDOJsonObject);
var
  LInfo: TJDOJsonObject;
  LServer: TMCPServer;
  LTTL: Integer;
begin
  if AResult = nil then
    Exit;
  LServer := TMCPServer(FServer);
  AResult.S['resultType'] := 'complete';

  LInfo := AResult.O['_meta'].O[MCP_META_SERVER_INFO];
  LInfo.S['name'] := LServer.ServerName;
  LInfo.S['version'] := LServer.ServerVersion;

  { CacheableResult: tools/list, prompts/list, resources/list,
    resources/templates/list, resources/read (and server/discover). The
    registry is fixed once the server serves, so lists may be kept; the
    content of a resource is data and may change at any moment. }
  if SameText(AMethod, 'resources/read') then
    LTTL := 0
  else if SameText(AMethod, 'tools/list') or SameText(AMethod, 'prompts/list') or
          SameText(AMethod, 'resources/list') or
          SameText(AMethod, 'resources/templates/list') or
          SameText(AMethod, 'server/discover') then
    LTTL := LServer.ListCacheTTLms
  else
    Exit;
  AResult.I['ttlMs'] := LTTL;
  AResult.S['cacheScope'] := ListCacheScope;
end;

function TMCPRequestHandler.DoServerDiscover: TJDOJsonObject;
var
  LServer: TMCPServer;
  LCaps: TMCPCapabilities;
begin
  LServer := TMCPServer(FServer);
  LCaps.SupportsTools := LServer.Tools.Count > 0;
  LCaps.SupportsResources := LServer.Resources.Count > 0;
  LCaps.SupportsPrompts := LServer.Prompts.Count > 0;

  Result := TJDOJsonObject.Create;
  Result.A['supportedVersions'].Add(MCP_PROTOCOL_VERSION_MODERN);
  Result.A['supportedVersions'].Add(MCP_PROTOCOL_VERSION);
  Result.O['capabilities'] := LCaps.ToJSON;
  if not LServer.ServerInstructions.IsEmpty then
    Result.S['instructions'] := LServer.ServerInstructions;
  DecorateResult('server/discover', Result);
end;

procedure TMCPRequestHandler.ValidateSession(const AMethod: string);
begin
  { Only the methods that can arrive before a session exists are exempt:
    `initialize` creates the session, `notifications/initialized` is the
    client's ack. Every other method (including `ping`) must present a
    valid session - the spec's session lifecycle is how the server knows
    a DELETE'd session is gone and a bogus one was never valid. }
  if SameText(AMethod, 'initialize') or
     SameText(AMethod, 'notifications/initialized') then
    Exit;

  if FSessionId.IsEmpty or
     not TMCPServer(FServer).SessionManager.SessionExists(FSessionId) then
    raise EMCPSessionError.Create(
      'Invalid or missing session. Send initialize first.');
end;

function TMCPRequestHandler.HandleRequest(ARequest: TJDOJsonObject): TJDOJsonObject;
var
  LMethod: string;
  LParams: TJDOJsonObject;
  LResult: TJDOJsonObject;
  LHasId: Boolean;
begin
  { JSON-RPC 2.0 spec: the "jsonrpc" member MUST be exactly "2.0" (section 4).
    The HTTP transport enforces this via DMVC's JSON-RPC dispatcher before
    HandleRequest ever runs, so this validation only fires on the direct
    (stdio) path. Raising Exception keeps the stdio transport simple: it
    already wraps exceptions into JSON-RPC error envelopes. }
  if not SameText(ARequest.S['jsonrpc'], '2.0') then
    raise EMCPInvalidRequest.Create(
      'Invalid Request. The JSON sent is not a valid Request object. ' +
      '[HINT] jsonrpc must be "2.0"');

  LMethod := ARequest.S['method'];
  LHasId := ARequest.Contains('id');

  { Extract params object if present }
  if ARequest.Contains('params') and (ARequest.Types['params'] = jdtObject) then
    LParams := ARequest.O['params']
  else
    LParams := nil;

  { Modern request: version and capabilities in _meta, no session. Legacy
    request: every method except initialize needs a valid session. }
  PrepareRequest(LMethod, LParams);

  { Dispatch to the correct handler }
  LResult := nil;
  if SameText(LMethod, 'initialize') then
    LResult := DoInitialize(LParams)
  else if SameText(LMethod, 'notifications/initialized') then
  begin
    DoNotificationsInitialized;
    { Notification: no response if no id }
    if not LHasId then
      Exit(nil);
  end
  else if SameText(LMethod, 'ping') then
    LResult := DoPing
  else if SameText(LMethod, 'server/discover') then
    LResult := DoServerDiscover
  else if SameText(LMethod, 'tools/list') then
    LResult := DoToolsList
  else if SameText(LMethod, 'tools/call') then
    LResult := DoToolsCall(LParams)
  else if SameText(LMethod, 'resources/list') then
    LResult := DoResourcesList
  else if SameText(LMethod, 'resources/templates/list') then
    LResult := DoResourcesTemplatesList
  else if SameText(LMethod, 'resources/read') then
    LResult := DoResourcesRead(LParams)
  else if SameText(LMethod, 'prompts/list') then
    LResult := DoPromptsList
  else if SameText(LMethod, 'prompts/get') then
    LResult := DoPromptsGet(LParams)
  else
  begin
    { JSON-RPC 2.0: unrecognized notifications MUST be silently ignored
      (a notification has no "id" and never receives a response or error).
      Clients like MCP Inspector send notifications/cancelled,
      notifications/progress etc. that this server has no use for - logging
      an error for each would just add noise to stderr. Requests (with id)
      still get a proper -32601 / -32603 error envelope. }
    if not LHasId then
      Exit(nil);
    if FModern then
      raise EMCPProtocolError.Create(-32601, 404, 'Method not found: ' + LMethod);
    raise Exception.CreateFmt('Unknown method: %s', [LMethod]);
  end;

  { For notifications (no id), return nil }
  if not LHasId then
  begin
    LResult.Free;
    Exit(nil);
  end;

  if FModern then
    DecorateResult(LMethod, LResult);

  { Build JSON-RPC response envelope }
  Result := TJDOJsonObject.Create;
  try
    Result.S['jsonrpc'] := '2.0';
    Result.O['result'] := LResult; { Ownership transferred }

    { Copy id preserving its type }
    case ARequest.Types['id'] of
      jdtString:
        Result.S['id'] := ARequest.S['id'];
      jdtInt:
        Result.I['id'] := ARequest.I['id'];
      jdtLong:
        Result.L['id'] := ARequest.L['id'];
      jdtFloat:
        Result.I['id'] := Round(ARequest.F['id']);
    else
      Result.S['id'] := ARequest.S['id'];
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ --- MCP protocol method implementations --- }

function TMCPRequestHandler.DoInitialize(AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LSession: IMCPSession;
  LClientInfo: TMCPClientInfo;
  LCaps: TMCPCapabilities;
begin
  LServer := TMCPServer(FServer);

  { Log if server identity is still at default values — developer reminder.
    Defaults are set in TMCPServer.Create; do NOT write here (race condition). }
  if LServer.ServerName = 'MCPServer' then
    LogW('MCP: ServerName is default "MCPServer". Set TMCPServer.Instance.ServerName in .dpr.');
  if LServer.ServerVersion = '1.0.0' then
    LogW('MCP: ServerVersion is default "1.0.0". Set TMCPServer.Instance.ServerVersion in .dpr.');

  { PC-1: Version negotiation }
  var LClientVersion: string;
  LClientVersion := '';
  if AParams <> nil then
    LClientVersion := AParams.S['protocolVersion'];
  if (not LClientVersion.IsEmpty) and (LClientVersion <> MCP_PROTOCOL_VERSION) then
    LogW('MCP: Client requested version "' + LClientVersion +
      '", server implements "' + MCP_PROTOCOL_VERSION + '". Responding with server version.');

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
  if not LServer.ServerInstructions.IsEmpty then
    Result.S['instructions'] := LServer.ServerInstructions;
end;

procedure TMCPRequestHandler.DoNotificationsInitialized;
begin
  { Notification - nothing to do, session already created in initialize }
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
  LToolObj, LAnn: TJDOJsonObject;
  LTools: TArray<TMCPToolInfo>;
begin
  LServer := TMCPServer(FServer);
  Result := TJDOJsonObject.Create;
  LToolsArray := Result.A['tools'];
  { Deterministic order (spec 2026-07-28: SHOULD): clients cache the list and
    LLM providers cache the prompt that contains it. }
  LTools := LServer.Tools.Values.ToArray;
  TArray.Sort<TMCPToolInfo>(LTools, TComparer<TMCPToolInfo>.Construct(
    function(const A, B: TMCPToolInfo): Integer
    begin
      Result := CompareText(A.Name, B.Name);
    end));
  for LToolInfo in LTools do
  begin
    LToolObj := LToolsArray.AddObject;
    LToolObj.S['name'] := LToolInfo.Name;
    if not LToolInfo.Title.IsEmpty then
      LToolObj.S['title'] := LToolInfo.Title;
    LToolObj.S['description'] := LToolInfo.Description;
    LToolObj.O['inputSchema'] :=
      TJDOJsonObject.Parse(LToolInfo.InputSchema.ToJSON(False)) as TJDOJsonObject;
    { Hints for the client UI and for the policy of the host: a read-only tool
      can be auto-approved, a destructive one needs a confirmation. }
    if LToolInfo.HasAnnotations then
    begin
      LAnn := LToolObj.O['annotations'];
      if not LToolInfo.Title.IsEmpty then
        LAnn.S['title'] := LToolInfo.Title;
      if LToolInfo.ReadOnly then
        LAnn.B['readOnlyHint'] := True;
      if LToolInfo.NonDestructive then
        LAnn.B['destructiveHint'] := False;
      if LToolInfo.Idempotent then
        LAnn.B['idempotentHint'] := True;
      if LToolInfo.ClosedWorld then
        LAnn.B['openWorldHint'] := False;
    end;
  end;
end;

function TMCPRequestHandler.DoToolsCall(AParams: TJDOJsonObject): TJDOJsonObject;

  function FindArgName(const AArguments: TJDOJsonObject; const AParamName: string): string;
  { Case-insensitive lookup: returns the actual JSON key matching AParamName, or '' if not found }
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
  LToolInfo: TMCPToolInfo;
  LProvider: TMCPToolProvider;
  LArgs: TArray<TValue>;
  LToolResult: TMCPToolResult;
  I: Integer;
  LArgKey: string;
  LName: string;
  LArguments: TJDOJsonObject;
begin
  LServer := TMCPServer(FServer);

  if AParams <> nil then
    LName := AParams.S['name']
  else
    LName := '';
  if LName.IsEmpty then
    raise Exception.Create('Missing tool name');

  if AParams.Contains('arguments') and (AParams.Types['arguments'] = jdtObject) then
    LArguments := AParams.O['arguments']
  else
    LArguments := nil;

  if not LServer.Tools.TryGetValue(LowerCase(LName), LToolInfo) then
  begin
    if FModern then
      raise EMCPProtocolError.Create(-32602, 0, 'Unknown tool: ' + LName);
    raise Exception.CreateFmt('Tool not found: %s', [LName]);
  end;

  { Validate required params (case-insensitive) }
  for I := 0 to High(LToolInfo.Params) do
  begin
    if LToolInfo.Params[I].Required and
       (FindArgName(LArguments, LToolInfo.Params[I].Name) = '') then
      raise Exception.CreateFmt(
        'Missing required parameter: %s', [LToolInfo.Params[I].Name]);
  end;

  { Dynamic dispatch (bridge/proxy tools) }
  if LToolInfo.HandlerInstance <> nil then
  begin
    LToolResult := LToolInfo.HandlerInstance.InvokeDynamic(LToolInfo.Name, LArguments);
    Result := LToolResult.ToJSON;
    Exit;
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
      { Default value for optional params }
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
    LProvider.Caller := FCaller;
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
  // MCP spec 2025-03-26: resources/list returns only concrete (static) resources.
  // Templated resources go to resources/templates/list. Mixing them here would
  // confuse clients that try to resources/read the literal {placeholder} URI.
  LServer := TMCPServer(FServer);
  Result := TJDOJsonObject.Create;
  LResArray := Result.A['resources'];
  for LInfo in LServer.Resources.Values do
  begin
    if LInfo.IsTemplate then
      Continue;
    LResObj := LResArray.AddObject;
    LResObj.S['uri'] := LInfo.URI;
    LResObj.S['name'] := LInfo.Name;
    LResObj.S['description'] := LInfo.Description;
    LResObj.S['mimeType'] := LInfo.MimeType;
  end;
end;

function TMCPRequestHandler.DoResourcesTemplatesList: TJDOJsonObject;
var
  LServer: TMCPServer;
  LResArray: TJDOJsonArray;
  LInfo: TMCPResourceInfo;
  LResObj: TJDOJsonObject;
begin
  { MCP spec 2025-03-26: resources/templates/list returns ResourceTemplate
    objects (uriTemplate, name, description, mimeType). The client expands
    the template locally and calls resources/read with the concretized URI;
    matching back to the template happens server-side in DoResourcesRead. }
  LServer := TMCPServer(FServer);
  Result := TJDOJsonObject.Create;
  LResArray := Result.A['resourceTemplates'];
  for LInfo in LServer.Resources.Values do
  begin
    if not LInfo.IsTemplate then
      Continue;
    LResObj := LResArray.AddObject;
    LResObj.S['uriTemplate'] := LInfo.URI;
    LResObj.S['name'] := LInfo.Name;
    LResObj.S['description'] := LInfo.Description;
    LResObj.S['mimeType'] := LInfo.MimeType;
  end;
end;

{ Tries to match a concrete URI against any registered template.
  Returns the matching resource info and the captured variable values
  (in template declaration order), or nil/empty when nothing matches.
  The first successful match wins; templates are unordered, so two
  templates that could both match the same URI are a developer error
  caught at scan time only if they have the same exact URI string. }
function FindMatchingTemplate(AServer: TMCPServer; const AURI: string;
  out AInfo: TMCPResourceInfo; out AValues: TArray<string>): Boolean;
var
  LCandidate: TMCPResourceInfo;
  LMatch: TMatch;
  I: Integer;
begin
  AInfo := nil;
  AValues := nil;
  for LCandidate in AServer.Resources.Values do
  begin
    if not LCandidate.IsTemplate then
      Continue;
    LMatch := LCandidate.Pattern.Match(AURI);
    if LMatch.Success then
    begin
      AInfo := LCandidate;
      SetLength(AValues, Length(LCandidate.VariableNames));
      { Group[0] is the full match, Group[1..N] are the captures }
      for I := 0 to High(LCandidate.VariableNames) do
        AValues[I] := LMatch.Groups[I + 1].Value;
      Exit(True);
    end;
  end;
  Result := False;
end;

function TMCPRequestHandler.DoResourcesRead(AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LInfo: TMCPResourceInfo;
  LProvider: TMCPResourceProvider;
  LResResult: TMCPResourceResult;
  LURI: string;
  LValues: TArray<string>;
  LArgs: TArray<TValue>;
  I: Integer;
  LNotFound: TJDOJsonObject;
begin
  LServer := TMCPServer(FServer);

  if AParams <> nil then
    LURI := AParams.S['uri']
  else
    LURI := '';
  if LURI.IsEmpty then
    raise Exception.Create('Missing resource URI');

  { Two-step lookup:
    1) Exact match on the static resource registry (fast path, O(1)).
    2) Template matching by linear scan over registered templates.
    Static resources keep their pre-templates dispatch performance; templates
    pay an O(N templates) regex scan only when the URI is not literally
    registered. The cost is dominated by the regex match itself, which is
    cheap for the simple [^/]+ patterns we generate. }
  if not LServer.Resources.TryGetValue(LowerCase(LURI), LInfo) then
  begin
    if not FindMatchingTemplate(LServer, LURI, LInfo, LValues) then
    begin
      { 2026-07-28 replaced -32002 with -32602, uri in data. }
      if FModern then
      begin
        LNotFound := TJDOJsonObject.Create;
        LNotFound.S['uri'] := LURI;
        raise EMCPProtocolError.Create(-32602, 0,
          'Resource not found: ' + LURI, LNotFound);
      end;
      raise Exception.Create('Resource not found: ' + LURI);
    end;
  end
  else if LInfo.IsTemplate then
    // A literal hit on a template URI is meaningless: a URI like
    // "scheme://x/{id}" is not a real resource, only a description of a
    // family of resources. Reject explicitly so that a misconfigured client
    // doesn't see an "unbound variable in URI" error from the user method.
    raise Exception.Create(
      'URI "' + LURI + '" is a template, not a concrete resource. ' +
      'Expand the {variables} and call resources/read with a real URI.');

  LProvider := LInfo.ProviderClass.Create;
  try
    LProvider.Caller := FCaller;
    if LInfo.IsTemplate then
    begin
      // Method signature: (URI, var1, var2, ...) all strings. Build the
      // argument array in declaration order — ValidateResourceSignature
      // already ensured arity and parameter names match at scan time.
      SetLength(LArgs, 1 + Length(LValues));
      LArgs[0] := TValue.From<string>(LURI);
      for I := 0 to High(LValues) do
        LArgs[I + 1] := TValue.From<string>(LValues[I]);
    end
    else
    begin
      SetLength(LArgs, 1);
      LArgs[0] := TValue.From<string>(LURI);
    end;
    LResResult := LInfo.RttiMethod.Invoke(LProvider, LArgs)
      .AsType<TMCPResourceResult>;
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

function TMCPRequestHandler.DoPromptsGet(AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LInfo: TMCPPromptInfo;
  LProvider: TMCPPromptProvider;
  LPromptResult: TMCPPromptResult;
  LArgs: TJDOJsonObject;
  LName: string;
  LOwnsArgs: Boolean;
begin
  LServer := TMCPServer(FServer);

  if AParams <> nil then
    LName := AParams.S['name']
  else
    LName := '';
  if LName.IsEmpty then
    raise Exception.Create('Missing prompt name');

  if not LServer.Prompts.TryGetValue(LowerCase(LName), LInfo) then
    raise Exception.Create('Prompt not found: ' + LName);

  LOwnsArgs := False;
  if (AParams <> nil) and AParams.Contains('arguments') and
     (AParams.Types['arguments'] = jdtObject) then
    LArgs := AParams.O['arguments']
  else
  begin
    LArgs := TJDOJsonObject.Create;
    LOwnsArgs := True;
  end;

  try
    LProvider := LInfo.ProviderClass.Create;
    try
      LProvider.Caller := FCaller;
      LPromptResult := LInfo.RttiMethod.Invoke(LProvider,
        [TValue.From<TJDOJsonObject>(LArgs)]).AsType<TMCPPromptResult>;
      Result := LPromptResult.ToJSON;
    finally
      LProvider.Free;
    end;
  finally
    if LOwnsArgs then
      LArgs.Free;
  end;
end;

end.
