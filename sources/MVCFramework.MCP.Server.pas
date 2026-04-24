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

unit MVCFramework.MCP.Server;

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  JsonDataObjects,
  MVCFramework, MVCFramework.Commons, MVCFramework.JSONRPC,
  MVCFramework.MCP.Types, MVCFramework.MCP.Attributes,
  MVCFramework.MCP.ToolProvider, MVCFramework.MCP.ResourceProvider, MVCFramework.MCP.PromptProvider,
  MVCFramework.MCP.Session, MVCFramework.MCP.RequestHandler;

type
  { Cached parameter descriptor - built once at registration }
  TMCPParamInfo = record
    Name: string;
    JsonSchemaType: string;
    Description: string;
    Required: Boolean;
    TypeKind: TTypeKind;
  end;

  { Cached tool descriptor }
  TMCPToolInfo = class
  public
    Name: string;
    Description: string;
    ProviderClass: TMCPToolProviderClass;
    RttiMethod: TRttiMethod;
    Params: TArray<TMCPParamInfo>;
    InputSchema: TJDOJsonObject;
    destructor Destroy; override;
  end;

  { Cached resource descriptor }
  TMCPResourceInfo = class
  public
    URI: string;
    Name: string;
    Description: string;
    MimeType: string;
    ProviderClass: TMCPResourceProviderClass;
    RttiMethod: TRttiMethod;
  end;

  { Cached prompt argument descriptor }
  TMCPPromptArgInfo = record
    Name: string;
    Description: string;
    Required: Boolean;
  end;

  { Cached prompt descriptor }
  TMCPPromptInfo = class
  public
    Name: string;
    Description: string;
    ProviderClass: TMCPPromptProviderClass;
    RttiMethod: TRttiMethod;
    Args: TArray<TMCPPromptArgInfo>;
  end;

  { -----------------------------------------------------------------------
    TMCPServer - shared registry, created once at startup.
    Scans providers via RTTI and caches all metadata.
    Thread-safe for reads (populated at startup, immutable after).
    ----------------------------------------------------------------------- }
  TMCPServer = class
  private class var
    FInstance: TMCPServer;
    FInstanceLock: TObject;
  private
    FServerName: string;
    FServerVersion: string;
    FSessionManager: IMCPSessionManager;
    FTools: TObjectDictionary<string, TMCPToolInfo>;
    FResources: TObjectDictionary<string, TMCPResourceInfo>;
    FPrompts: TObjectDictionary<string, TMCPPromptInfo>;
    FRttiContext: TRttiContext;

    procedure ScanToolProvider(AProviderClass: TMCPToolProviderClass);
    procedure ScanResourceProvider(AProviderClass: TMCPResourceProviderClass);
    procedure ScanPromptProvider(AProviderClass: TMCPPromptProviderClass);

    class function DelphiTypeToJsonSchema(ATypeKind: TTypeKind; ATypeHandle: PTypeInfo): string;
    function BuildInputSchemaFromParams(const AParams: TArray<TMCPParamInfo>): TJDOJsonObject;
  public
    constructor Create(ASessionManager: IMCPSessionManager = nil);
    destructor Destroy; override;
    class constructor ClassCreate;
    class destructor ClassDestroy;

    { Singleton accessor. Thread-safe, creates the instance on first call. }
    class function Instance: TMCPServer;

    procedure RegisterToolProvider(AProviderClass: TMCPToolProviderClass);
    procedure RegisterResourceProvider(AProviderClass: TMCPResourceProviderClass);
    procedure RegisterPromptProvider(AProviderClass: TMCPPromptProviderClass);

    { Creates a published endpoint for use with TMVCEngine.PublishObject }
    function CreatePublishedEndpoint: TObject;

    property ServerName: string read FServerName write FServerName;
    property ServerVersion: string read FServerVersion write FServerVersion;
    property SessionManager: IMCPSessionManager read FSessionManager;
    property Tools: TObjectDictionary<string, TMCPToolInfo> read FTools;
    property Resources: TObjectDictionary<string, TMCPResourceInfo> read FResources;
    property Prompts: TObjectDictionary<string, TMCPPromptInfo> read FPrompts;
  end;

  { -----------------------------------------------------------------------
    TMCPEndpoint - published object, created per request by PublishObject.
    Methods are exposed as JSON-RPC by DMVCFramework.
    Slashes are stripped from MCP method names in OnBeforeRoutingHook
    (e.g. tools/list -> ToolsList) for case-insensitive RTTI dispatch.
    ----------------------------------------------------------------------- }
  TMCPEndpoint = class
  private
    FServer: TMCPServer;
    FSessionId: string;
    FHandler: TMCPRequestHandler;
  public
    constructor Create(AServer: TMCPServer);
    destructor Destroy; override;

    { Hooks called by DMVCFramework JSONRPC publisher }
    procedure OnBeforeRoutingHook(const Context: TWebContext; const JSON: TJDOJsonObject);
    procedure OnAfterCallHook(const Context: TWebContext; const JSONResponse: TJDOJsonObject);

    { MCP protocol methods.
      Slashes in MCP method names (e.g. tools/list) are stripped by OnBeforeRoutingHook
      so that tools/list -> ToolsList. The dispatcher uses SameText (case-insensitive). }
    function Initialize(const ProtocolVersion: string;
      [MVCJSONRPCOptional] const Capabilities: TJDOJsonObject;
      [MVCJSONRPCOptional] const ClientInfo: TJDOJsonObject;
      [MVCJSONRPCRestParams] const ExtraParams: TJDOJsonArray): TJDOJsonObject;
    procedure NotificationsInitialized;
    function Ping: TJDOJsonObject;
    function ToolsList: TJDOJsonObject;
    function ToolsCall(const Name: string;
      [MVCJSONRPCOptional] const Arguments: TJDOJsonObject;
      [MVCJSONRPCRestParams] const ExtraParams: TJDOJsonArray): TJDOJsonObject;
    function ResourcesList: TJDOJsonObject;
    function ResourcesTemplatesList: TJDOJsonObject;
    function ResourcesRead(const URI: string;
      [MVCJSONRPCRestParams] const ExtraParams: TJDOJsonArray): TJDOJsonObject;
    function PromptsList: TJDOJsonObject;
    function PromptsGet(const Name: string;
      [MVCJSONRPCOptional] const Arguments: TJDOJsonObject;
      [MVCJSONRPCRestParams] const ExtraParams: TJDOJsonArray): TJDOJsonObject;
  end;

  { -----------------------------------------------------------------------
    TMCPSessionController - handles DELETE on the MCP endpoint for session
    cleanup as required by the MCP transport specification.
    Ref: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#session-management
    ----------------------------------------------------------------------- }
  [MVCPath(MCP_ENDPOINT)]
  TMCPSessionController = class(TMVCController)
  public
    [MVCPath]
    [MVCHTTPMethod([httpDELETE])]
    procedure DestroySession;
  end;

implementation

uses
  MVCFramework.Logger;

{ TMCPToolInfo }

destructor TMCPToolInfo.Destroy;
begin
  InputSchema.Free;
  inherited;
end;

{ =========================================================================
  TMCPServer - Registry
  ========================================================================= }

constructor TMCPServer.Create(ASessionManager: IMCPSessionManager);
begin
  inherited Create;
  FTools := TObjectDictionary<string, TMCPToolInfo>.Create([doOwnsValues]);
  FResources := TObjectDictionary<string, TMCPResourceInfo>.Create([doOwnsValues]);
  FPrompts := TObjectDictionary<string, TMCPPromptInfo>.Create([doOwnsValues]);
  FRttiContext := TRttiContext.Create;
  if ASessionManager <> nil then
    FSessionManager := ASessionManager
  else
    FSessionManager := TMCPInMemorySessionManager.Create;
end;

class constructor TMCPServer.ClassCreate;
begin
  FInstanceLock := TObject.Create;
end;

class function TMCPServer.Instance: TMCPServer;
begin
  if not Assigned(FInstance) then
  begin
    TMonitor.Enter(FInstanceLock);
    try
      if not Assigned(FInstance) then
        FInstance := TMCPServer.Create;
    finally
      TMonitor.Exit(FInstanceLock);
    end;
  end;
  Result := FInstance;
end;

class destructor TMCPServer.ClassDestroy;
begin
  FreeAndNil(FInstance);
  FreeAndNil(FInstanceLock);
end;

destructor TMCPServer.Destroy;
begin
  FTools.Free;
  FResources.Free;
  FPrompts.Free;
  FRttiContext.Free;
  inherited;
end;

function TMCPServer.CreatePublishedEndpoint: TObject;
begin
  Result := TMCPEndpoint.Create(Self);
end;

procedure TMCPServer.RegisterToolProvider(AProviderClass: TMCPToolProviderClass);
begin
  ScanToolProvider(AProviderClass);
end;

procedure TMCPServer.RegisterResourceProvider(AProviderClass: TMCPResourceProviderClass);
begin
  ScanResourceProvider(AProviderClass);
end;

procedure TMCPServer.RegisterPromptProvider(AProviderClass: TMCPPromptProviderClass);
begin
  ScanPromptProvider(AProviderClass);
end;

{ --- RTTI scanning at startup --- }

class function TMCPServer.DelphiTypeToJsonSchema(ATypeKind: TTypeKind; ATypeHandle: PTypeInfo): string;
begin
  case ATypeKind of
    tkUString, tkString, tkLString, tkWString, tkChar, tkWChar:
      Result := 'string';
    tkInteger, tkInt64:
      Result := 'integer';
    tkFloat:
      Result := 'number';
    tkEnumeration:
      if ATypeHandle = TypeInfo(Boolean) then
        Result := 'boolean'
      else
        Result := 'string';
  else
    Result := 'object';
  end;
end;

function TMCPServer.BuildInputSchemaFromParams(const AParams: TArray<TMCPParamInfo>): TJDOJsonObject;
var
  LProperties: TJDOJsonObject;
  LRequired: TJDOJsonArray;
  I: Integer;
begin
  Result := TJDOJsonObject.Create;
  Result.S['type'] := 'object';
  LProperties := Result.O['properties'];
  LRequired := nil;

  for I := 0 to High(AParams) do
  begin
    LProperties.O[AParams[I].Name].S['type'] := AParams[I].JsonSchemaType;
    if not AParams[I].Description.IsEmpty then
      LProperties.O[AParams[I].Name].S['description'] := AParams[I].Description;
    if AParams[I].Required then
    begin
      if LRequired = nil then
        LRequired := Result.A['required'];
      LRequired.Add(AParams[I].Name);
    end;
  end;
end;

procedure TMCPServer.ScanToolProvider(AProviderClass: TMCPToolProviderClass);
var
  LRttiType: TRttiType;
  LMethod: TRttiMethod;
  LAttr: TCustomAttribute;
  LToolAttr: MCPToolAttribute;
  LToolInfo: TMCPToolInfo;
  LRttiParams: TArray<TRttiParameter>;
  LParamAttr: MCPParamAttribute;
  I: Integer;
  LParamInfo: TMCPParamInfo;
  LKey: string;
begin
  LRttiType := FRttiContext.GetType(AProviderClass);
  if LRttiType = nil then
    Exit;

  for LMethod in LRttiType.GetMethods do
  begin
    LToolAttr := nil;
    for LAttr in LMethod.GetAttributes do
    begin
      if LAttr is MCPToolAttribute then
      begin
        LToolAttr := MCPToolAttribute(LAttr);
        Break;
      end;
    end;

    if LToolAttr = nil then
      Continue;

    LToolInfo := TMCPToolInfo.Create;
    try
      LToolInfo.Name := LToolAttr.Name;
      LToolInfo.Description := LToolAttr.Description;
      LToolInfo.ProviderClass := AProviderClass;
      LToolInfo.RttiMethod := LMethod;

      LRttiParams := LMethod.GetParameters;
      SetLength(LToolInfo.Params, Length(LRttiParams));

      for I := 0 to High(LRttiParams) do
      begin
        LParamInfo.Name := LRttiParams[I].Name;
        LParamInfo.TypeKind := LRttiParams[I].ParamType.TypeKind;
        LParamInfo.JsonSchemaType := DelphiTypeToJsonSchema(
          LRttiParams[I].ParamType.TypeKind,
          LRttiParams[I].ParamType.Handle);

        LParamAttr := nil;
        for LAttr in LRttiParams[I].GetAttributes do
        begin
          if LAttr is MCPParamAttribute then
          begin
            LParamAttr := MCPParamAttribute(LAttr);
            Break;
          end;
        end;

        if LParamAttr = nil then
          raise Exception.CreateFmt(
            'Tool "%s": parameter "%s" is missing [MCPParam] attribute',
            [LToolAttr.Name, LParamInfo.Name]);

        LParamInfo.Description := LParamAttr.Description;
        LParamInfo.Required := LParamAttr.Required;
        LToolInfo.Params[I] := LParamInfo;
      end;

      LToolInfo.InputSchema := BuildInputSchemaFromParams(LToolInfo.Params);

      LKey := LowerCase(LToolInfo.Name);
      if FTools.ContainsKey(LKey) then
        raise Exception.CreateFmt('Duplicate tool name: "%s"', [LToolInfo.Name]);
      FTools.Add(LKey, LToolInfo);
    except
      LToolInfo.Free;
      raise;
    end;

    LogI('MCP: Registered tool "' + LToolAttr.Name + '" with ' +
      IntToStr(Length(LRttiParams)) + ' param(s)');
  end;
end;

procedure TMCPServer.ScanResourceProvider(AProviderClass: TMCPResourceProviderClass);
var
  LRttiType: TRttiType;
  LMethod: TRttiMethod;
  LAttr: TCustomAttribute;
  LResAttr: MCPResourceAttribute;
  LInfo: TMCPResourceInfo;
  LKey: string;
begin
  LRttiType := FRttiContext.GetType(AProviderClass);
  if LRttiType = nil then
    Exit;

  for LMethod in LRttiType.GetMethods do
  begin
    for LAttr in LMethod.GetAttributes do
    begin
      if LAttr is MCPResourceAttribute then
      begin
        LResAttr := MCPResourceAttribute(LAttr);
        LInfo := TMCPResourceInfo.Create;
        try
          LInfo.URI := LResAttr.URI;
          LInfo.Name := LResAttr.Name;
          LInfo.Description := LResAttr.Description;
          LInfo.MimeType := LResAttr.MimeType;
          LInfo.ProviderClass := AProviderClass;
          LInfo.RttiMethod := LMethod;

          LKey := LowerCase(LInfo.URI);
          if FResources.ContainsKey(LKey) then
            raise Exception.CreateFmt('Duplicate resource URI: "%s"', [LInfo.URI]);
          FResources.Add(LKey, LInfo);
        except
          LInfo.Free;
          raise;
        end;
        LogI('MCP: Registered resource "' + LResAttr.Name + '" (' + LResAttr.URI + ')');
      end;
    end;
  end;
end;

procedure TMCPServer.ScanPromptProvider(AProviderClass: TMCPPromptProviderClass);
var
  LRttiType: TRttiType;
  LMethod: TRttiMethod;
  LAttr, LInnerAttr: TCustomAttribute;
  LPromptAttr: MCPPromptAttribute;
  LArgAttr: MCPPromptArgAttribute;
  LInfo: TMCPPromptInfo;
  LKey: string;
begin
  LRttiType := FRttiContext.GetType(AProviderClass);
  if LRttiType = nil then
    Exit;

  for LMethod in LRttiType.GetMethods do
  begin
    LPromptAttr := nil;
    for LAttr in LMethod.GetAttributes do
    begin
      if LAttr is MCPPromptAttribute then
      begin
        LPromptAttr := MCPPromptAttribute(LAttr);
        Break;
      end;
    end;

    if LPromptAttr = nil then
      Continue;

    LInfo := TMCPPromptInfo.Create;
    try
      LInfo.Name := LPromptAttr.Name;
      LInfo.Description := LPromptAttr.Description;
      LInfo.ProviderClass := AProviderClass;
      LInfo.RttiMethod := LMethod;

      for LInnerAttr in LMethod.GetAttributes do
      begin
        if LInnerAttr is MCPPromptArgAttribute then
        begin
          LArgAttr := MCPPromptArgAttribute(LInnerAttr);
          SetLength(LInfo.Args, Length(LInfo.Args) + 1);
          LInfo.Args[High(LInfo.Args)].Name := LArgAttr.Name;
          LInfo.Args[High(LInfo.Args)].Description := LArgAttr.Description;
          LInfo.Args[High(LInfo.Args)].Required := LArgAttr.Required;
        end;
      end;

      LKey := LowerCase(LInfo.Name);
      if FPrompts.ContainsKey(LKey) then
        raise Exception.CreateFmt('Duplicate prompt name: "%s"', [LInfo.Name]);
      FPrompts.Add(LKey, LInfo);
    except
      LInfo.Free;
      raise;
    end;
    LogI('MCP: Registered prompt "' + LPromptAttr.Name + '"');
  end;
end;

{ =========================================================================
  TMCPEndpoint - Published object (one per request)
  ========================================================================= }

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

{ --- Hooks --- }

procedure TMCPEndpoint.OnBeforeRoutingHook(const Context: TWebContext; const JSON: TJDOJsonObject);
var
  LMethod: string;
begin
  LMethod := JSON.S[JSONRPC_METHOD];
  JSON.S[JSONRPC_METHOD] := LMethod.Replace('/', '');

  { Always capture the incoming session id. It is empty for the very first
    `initialize` call (that is how the client signals "give me a session")
    but present on every subsequent request - including `ping`. Storing it
    here unconditionally lets OnAfterCallHook echo it back via
    `Mcp-Session-Id`, which the MCP spec requires on every response
    after initialize. }
  FSessionId := Context.Request.Headers[MCP_SESSION_HEADER];
  FHandler.SessionId := FSessionId;

  { Validation is skipped only for methods that can legitimately arrive
    without a session: `initialize` creates one, and
    `notifications/initialized` is the client's fire-and-forget ack. Every
    other method - `ping` included - must carry a valid session or the
    server replies with a JSON-RPC error. }
  if not SameText(LMethod, 'initialize') and
     not SameText(LMethod, 'notifications/initialized') then
  begin
    try
      FHandler.ValidateSession(LMethod);
    except
      on E: EMCPSessionError do
        raise EMVCJSONRPCError.Create(JSONRPC_ERR_INVALID_REQUEST, E.Message);
    end;
  end;
end;

procedure TMCPEndpoint.OnAfterCallHook(const Context: TWebContext; const JSONResponse: TJDOJsonObject);
begin
  { Set session header on every response }
  if not FSessionId.IsEmpty then
    Context.Response.SetCustomHeader(MCP_SESSION_HEADER, FSessionId);

  { MCP Streamable HTTP transport: notifications must return 202 Accepted
    (JSON-RPC framework returns 204 No Content by default).
    Ref: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#sending-notifications-1 }
  if Context.Response.StatusCode = 204 then
    Context.Response.StatusCode := 202;
end;

{ --- MCP protocol methods --- }

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
      LParams.O['capabilities'] :=
        TJDOJsonObject.Parse(Capabilities.ToJSON(False)) as TJDOJsonObject;
    if ClientInfo <> nil then
      LParams.O['clientInfo'] :=
        TJDOJsonObject.Parse(ClientInfo.ToJSON(False)) as TJDOJsonObject;
    Result := FHandler.DoInitialize(LParams);
    FSessionId := FHandler.SessionId;
  finally
    LParams.Free;
  end;
end;

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
      LParams.O['arguments'] :=
        TJDOJsonObject.Parse(Arguments.ToJSON(False)) as TJDOJsonObject;
    Result := FHandler.DoToolsCall(LParams);
  finally
    LParams.Free;
  end;
end;

function TMCPEndpoint.ResourcesList: TJDOJsonObject;
begin
  Result := FHandler.DoResourcesList;
end;

function TMCPEndpoint.ResourcesTemplatesList: TJDOJsonObject;
begin
  Result := FHandler.DoResourcesTemplatesList;
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
      LParams.O['arguments'] :=
        TJDOJsonObject.Parse(Arguments.ToJSON(False)) as TJDOJsonObject;
    Result := FHandler.DoPromptsGet(LParams);
  finally
    LParams.Free;
  end;
end;

{ TMCPSessionController }

procedure TMCPSessionController.DestroySession;
var
  LSessionId: string;
  LErr: TJDOJsonObject;
begin
  LSessionId := Context.Request.Headers[MCP_SESSION_HEADER];
  if LSessionId.IsEmpty then
  begin
    ResponseStatus(400);
    LErr := TJDOJsonObject.Create;
    LErr.S['error'] := 'Missing session id';
    Render(LErr, True);
    Exit;
  end;

  if not TMCPServer.Instance.SessionManager.SessionExists(LSessionId) then
  begin
    ResponseStatus(404);
    LErr := TJDOJsonObject.Create;
    LErr.S['error'] := 'Session not found';
    Render(LErr, True);
    Exit;
  end;

  TMCPServer.Instance.SessionManager.DestroySession(LSessionId);
  LogI('MCP: Session destroyed ' + LSessionId);
  ResponseStatus(204);
end;

end.
