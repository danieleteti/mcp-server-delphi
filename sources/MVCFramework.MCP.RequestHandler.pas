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
  System.SysUtils, System.Rtti,
  JsonDataObjects;

type
  EMCPSessionError = class(Exception);

  { -----------------------------------------------------------------------
    TMCPRequestHandler - transport-agnostic MCP protocol dispatch.
    Encapsulates all MCP method handling without any HTTP dependency.
    Used by both TMCPEndpoint (HTTP) and TMCPStdioTransport (stdio).
    ----------------------------------------------------------------------- }
  TMCPRequestHandler = class
  private
    FServer: TObject;  { Actually TMCPServer; typed as TObject to avoid circular reference }
    FSessionId: string;
  public
    constructor Create(AServer: TObject);

    { Main entry point: dispatches a parsed JSON-RPC request and returns
      the JSON-RPC response. Returns nil for notifications (no id). }
    function HandleRequest(ARequest: TJDOJsonObject): TJDOJsonObject;

    { Session validation: raises EMCPSessionError for non-initialize
      methods when the session is missing or invalid. }
    procedure ValidateSession(const AMethod: string);

    { Individual MCP method handlers - public so transports can call them directly }
    function DoInitialize(AParams: TJDOJsonObject): TJDOJsonObject;
    procedure DoNotificationsInitialized;
    function DoPing: TJDOJsonObject;
    function DoToolsList: TJDOJsonObject;
    function DoToolsCall(AParams: TJDOJsonObject): TJDOJsonObject;
    function DoResourcesList: TJDOJsonObject;
    function DoResourcesRead(AParams: TJDOJsonObject): TJDOJsonObject;
    function DoPromptsList: TJDOJsonObject;
    function DoPromptsGet(AParams: TJDOJsonObject): TJDOJsonObject;

    property SessionId: string read FSessionId write FSessionId;
  end;

implementation

uses
  System.TypInfo,
  MVCFramework.Logger,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Types,
  MVCFramework.MCP.ToolProvider,
  MVCFramework.MCP.ResourceProvider,
  MVCFramework.MCP.PromptProvider,
  MVCFramework.MCP.Session;

{ TMCPRequestHandler }

constructor TMCPRequestHandler.Create(AServer: TObject);
begin
  inherited Create;
  FServer := AServer;
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
  LMethod := ARequest.S['method'];
  LHasId := ARequest.Contains('id');

  { Session validation: all methods except initialize/ping require a valid session }
  ValidateSession(LMethod);

  { Extract params object if present }
  if ARequest.Contains('params') and (ARequest.Types['params'] = jdtObject) then
    LParams := ARequest.O['params']
  else
    LParams := nil;

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

  { For notifications (no id), return nil }
  if not LHasId then
  begin
    LResult.Free;
    Exit(nil);
  end;

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

  { Apply defaults for unconfigured server identity }
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
    raise Exception.CreateFmt('Tool not found: %s', [LName]);

  { Validate required params (case-insensitive) }
  for I := 0 to High(LToolInfo.Params) do
  begin
    if LToolInfo.Params[I].Required and
       (FindArgName(LArguments, LToolInfo.Params[I].Name) = '') then
      raise Exception.CreateFmt(
        'Missing required parameter: %s', [LToolInfo.Params[I].Name]);
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

function TMCPRequestHandler.DoResourcesRead(AParams: TJDOJsonObject): TJDOJsonObject;
var
  LServer: TMCPServer;
  LInfo: TMCPResourceInfo;
  LProvider: TMCPResourceProvider;
  LResResult: TMCPResourceResult;
  LURI: string;
begin
  LServer := TMCPServer(FServer);

  if AParams <> nil then
    LURI := AParams.S['uri']
  else
    LURI := '';
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
