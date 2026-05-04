// *** MVCFramework.MCP.Bridge — GENERATED SCAFFOLD — implementation pending ***
unit MVCFramework.MCP.Bridge;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Net.HttpClient, System.TypInfo,
  MVCFramework,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.ToolProvider,
  JsonDataObjects;

type
  EMCPBridgeException = class(Exception);

  TMCPBridgeParamKind = (bpkPath, bpkQuery, bpkBody);

  TMCPBridgeParamInfo = record
    Name: string;
    Description: string;
    Required: Boolean;
    Kind: TMCPBridgeParamKind;
    JsonSchemaType: string;
  end;

  TMCPBridgeRouteInfo = class
  public
    ToolName: string;
    Description: string;
    HTTPMethod: string;
    PathTemplate: string;
    ControllerClassName: string;
    Params: TArray<TMCPBridgeParamInfo>;
    destructor Destroy; override;
  end;

  TMCPEngineScanner = class
  private
    FEngine: TMVCEngine;
    function CamelToSnake(const AName: string): string;
    function PathToToolName(const AMethod, APath: string): string;
    function DelphiTypeToJsonSchema(ATypeInfo: PTypeInfo): string;
  public
    constructor Create(AEngine: TMVCEngine);
    function Scan: TArray<TMCPBridgeRouteInfo>;
  end;

  TMCPBridgeProvider = class(TMCPToolProvider)
  private
    FBaseURL: string;
    FRoutes: TObjectList<TMCPBridgeRouteInfo>;
    FHttpClient: TNetHTTPClient;
    function FindRoute(const AToolName: string): TMCPBridgeRouteInfo;
    function BuildURL(ARoute: TMCPBridgeRouteInfo; AArguments: TJDOJsonObject): string;
    function BuildQueryString(ARoute: TMCPBridgeRouteInfo; AArguments: TJDOJsonObject): string;
  public
    constructor Create(const ABaseURL: string); reintroduce;
    destructor Destroy; override;
    procedure AddRoute(ARoute: TMCPBridgeRouteInfo);
    property Routes: TObjectList<TMCPBridgeRouteInfo> read FRoutes;
    function GetDynamicToolDefs: TArray<TMCPDynamicToolDef>; override;
    function InvokeDynamic(const AToolName: string; AArguments: TJDOJsonObject): TMCPToolResult; override;
  end;

  TMCPBridgeCodeGen = class
  private
    FServer: TMCPServer;
    function ToolNameToMethodName(const AToolName: string): string;
    function ToolNameToProviderName(const AControllerClassName: string): string;
    procedure WriteProviderFile(const AOutputPath, AControllerClassName: string; ARoutes: TArray<TMCPBridgeRouteInfo>);
  public
    constructor Create(AServer: TMCPServer);
    procedure GenerateAll(const AOutputPath: string);
  end;

  TMCPServerBridgeHelper = class helper for TMCPServer
  public
    procedure RegisterFromEngine(AEngine: TMVCEngine; const ABaseURL: string);
    procedure GenerateProviderUnit(const AOutputPath: string);
  end;

implementation

uses
  System.IOUtils, System.Rtti;

{ TMCPBridgeRouteInfo }

destructor TMCPBridgeRouteInfo.Destroy;
begin
  inherited;
end;

{ TMCPEngineScanner }

constructor TMCPEngineScanner.Create(AEngine: TMVCEngine);
begin
  inherited Create;
  FEngine := AEngine;
end;

function TMCPEngineScanner.CamelToSnake(const AName: string): string;
var
  I: Integer;
  LResult: TStringBuilder;
begin
  LResult := TStringBuilder.Create;
  try
    for I := 1 to Length(AName) do
    begin
      if (I > 1) and (AName[I] in ['A'..'Z']) then
      begin
        // Insert underscore if: previous char is lowercase, OR
        // this char is uppercase and next char is lowercase (handles HTMLParser → html_parser)
        if (AName[I-1] in ['a'..'z']) or
           ((I < Length(AName)) and (AName[I+1] in ['a'..'z']) and (AName[I-1] in ['A'..'Z'])) then
          LResult.Append('_');
      end;
      LResult.Append(LowerCase(AName[I]));
    end;
    Result := LResult.ToString;
  finally
    LResult.Free;
  end;
end;

function TMCPEngineScanner.PathToToolName(const AMethod, APath: string): string;
var
  LPath: string;
  LParts: TArray<string>;
  I: Integer;
  LPart: string;
  LResult: TStringBuilder;
begin
  LPath := APath;
  // Remove leading slash
  if (LPath <> '') and (LPath[1] = '/') then
    LPath := Copy(LPath, 2, MaxInt);

  LParts := LPath.Split(['/']);
  LResult := TStringBuilder.Create;
  try
    LResult.Append(LowerCase(AMethod));
    for I := 0 to High(LParts) do
    begin
      LPart := LParts[I];
      if LPart = '' then Continue;
      LResult.Append('_');
      // Check if it's a path parameter {varName}
      if (Length(LPart) >= 3) and (LPart[1] = '{') and (LPart[Length(LPart)] = '}') then
      begin
        LResult.Append('by_');
        LResult.Append(CamelToSnake(Copy(LPart, 2, Length(LPart) - 2)));
      end
      else
        LResult.Append(LPart);
    end;
    Result := LResult.ToString;
  finally
    LResult.Free;
  end;
end;

function TMCPEngineScanner.DelphiTypeToJsonSchema(ATypeInfo: PTypeInfo): string;
begin
  if ATypeInfo = nil then
    Exit('string');
  case ATypeInfo^.Kind of
    tkInteger, tkInt64:
      Result := 'integer';
    tkFloat:
      Result := 'number';
    tkEnumeration:
      if ATypeInfo = System.TypeInfo(Boolean) then
        Result := 'boolean'
      else
        Result := 'string';
    tkUString, tkString, tkLString, tkWString:
      Result := 'string';
  else
    Result := 'string';
  end;
end;

function TMCPEngineScanner.Scan: TArray<TMCPBridgeRouteInfo>;
begin
  raise Exception.Create('Not implemented');
end;

{ TMCPBridgeProvider }

constructor TMCPBridgeProvider.Create(const ABaseURL: string);
begin
  inherited Create;
  FBaseURL := ABaseURL;
  FRoutes := TObjectList<TMCPBridgeRouteInfo>.Create(True);
  FHttpClient := TNetHTTPClient.Create(nil);
end;

destructor TMCPBridgeProvider.Destroy;
begin
  FHttpClient.Free;
  FRoutes.Free;
  inherited;
end;

procedure TMCPBridgeProvider.AddRoute(ARoute: TMCPBridgeRouteInfo);
begin
  raise Exception.Create('Not implemented');
end;

function TMCPBridgeProvider.FindRoute(const AToolName: string): TMCPBridgeRouteInfo;
begin
  raise Exception.Create('Not implemented');
end;

function TMCPBridgeProvider.BuildURL(ARoute: TMCPBridgeRouteInfo; AArguments: TJDOJsonObject): string;
begin
  raise Exception.Create('Not implemented');
end;

function TMCPBridgeProvider.BuildQueryString(ARoute: TMCPBridgeRouteInfo; AArguments: TJDOJsonObject): string;
begin
  raise Exception.Create('Not implemented');
end;

function TMCPBridgeProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;
begin
  raise Exception.Create('Not implemented');
end;

function TMCPBridgeProvider.InvokeDynamic(const AToolName: string; AArguments: TJDOJsonObject): TMCPToolResult;
begin
  raise Exception.Create('Not implemented');
end;

{ TMCPBridgeCodeGen }

constructor TMCPBridgeCodeGen.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
end;

function TMCPBridgeCodeGen.ToolNameToMethodName(const AToolName: string): string;
begin
  raise Exception.Create('Not implemented');
end;

function TMCPBridgeCodeGen.ToolNameToProviderName(const AControllerClassName: string): string;
begin
  raise Exception.Create('Not implemented');
end;

procedure TMCPBridgeCodeGen.WriteProviderFile(const AOutputPath, AControllerClassName: string; ARoutes: TArray<TMCPBridgeRouteInfo>);
begin
  raise Exception.Create('Not implemented');
end;

procedure TMCPBridgeCodeGen.GenerateAll(const AOutputPath: string);
begin
  raise Exception.Create('Not implemented');
end;

{ TMCPServerBridgeHelper }

procedure TMCPServerBridgeHelper.RegisterFromEngine(AEngine: TMVCEngine; const ABaseURL: string);
begin
  raise Exception.Create('Not implemented');
end;

procedure TMCPServerBridgeHelper.GenerateProviderUnit(const AOutputPath: string);
begin
  raise Exception.Create('Not implemented');
end;

end.
