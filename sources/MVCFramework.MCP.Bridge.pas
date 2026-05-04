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
    TypeKind: TTypeKind;
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
    FHttpClient: THTTPClient;
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
  System.IOUtils, System.Rtti, System.NetEncoding,
  System.Net.URLClient, System.NetConsts, MVCFramework.Logger;

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
      if (I > 1) and CharInSet(AName[I], ['A'..'Z']) then
      begin
        if CharInSet(AName[I-1], ['a'..'z']) or
           ((I < Length(AName)) and CharInSet(AName[I+1], ['a'..'z']) and CharInSet(AName[I-1], ['A'..'Z'])) then
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
      // DMVCFramework path params use ($name) or ($name:type) syntax
      if (Length(LPart) >= 4) and (LPart[1] = '(') and (LPart[2] = '$') and (LPart[Length(LPart)] = ')') then
      begin
        var LVarName := Copy(LPart, 3, Length(LPart) - 3);
        var LColon := Pos(':', LVarName);
        if LColon > 0 then
          LVarName := Copy(LVarName, 1, LColon - 1);
        LResult.Append('by_');
        LResult.Append(CamelToSnake(LVarName));
      end
      else
        LResult.Append(LowerCase(LPart));
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
var
  LCtx: TRttiContext;
  LDelegate: TMVCControllerDelegate;
  LRttiType: TRttiType;
  LMethod: TRttiMethod;
  LAttr, LParamAttr: TCustomAttribute;
  LPathAttr: MVCPathAttribute;
  LMethodAttr: MVCHTTPMethodsAttribute;
  LDocAttr: MVCDocAttribute;
  LBasePath, LActionPath, LFullPath, LHTTPMethod: string;
  LRoute: TMCPBridgeRouteInfo;
  LParam: TRttiParameter;
  LBridgeParam: TMCPBridgeParamInfo;
  LFromQuery: MVCFromQueryStringAttribute;
  LFromBody: MVCFromBodyAttribute;
  LToolName: string;
  LSeenNames: TDictionary<string, string>;
  LPrefixedName: string;
  LCommaPos: Integer;
  LParamSegment: string;
  LIsPathParam: Boolean;
begin
  Result := nil;
  LSeenNames := TDictionary<string, string>.Create;
  LCtx := TRttiContext.Create;
  try
    for LDelegate in FEngine.Controllers do
    begin
      LRttiType := LCtx.GetType(LDelegate.Clazz);
      if LRttiType = nil then Continue;

      LBasePath := '';
      for LAttr in LRttiType.GetAttributes do
        if LAttr is MVCPathAttribute then
        begin
          LBasePath := MVCPathAttribute(LAttr).Path;
          Break;
        end;
      if LBasePath = '' then Continue;  // skip controllers without [MVCPath]

      for LMethod in LRttiType.GetMethods do
      begin
        LMethodAttr := nil;
        LPathAttr   := nil;
        LDocAttr    := nil;

        for LAttr in LMethod.GetAttributes do
        begin
          if LAttr is MVCHTTPMethodsAttribute then
            LMethodAttr := MVCHTTPMethodsAttribute(LAttr)
          else if LAttr is MVCPathAttribute then
            LPathAttr := MVCPathAttribute(LAttr)
          else if LAttr is MVCDocAttribute then
            LDocAttr := MVCDocAttribute(LAttr);
        end;

        if LMethodAttr = nil then Continue;  // not an action

        LActionPath := '';
        if LPathAttr <> nil then
          LActionPath := LPathAttr.Path;
        LFullPath := LBasePath + LActionPath;

        // MVCHTTPMethodsAsString returns enum names like 'httpGET,httpPOST'
        LHTTPMethod := LMethodAttr.MVCHTTPMethodsAsString;
        LCommaPos := Pos(',', LHTTPMethod);
        if LCommaPos > 0 then
          LHTTPMethod := Copy(LHTTPMethod, 1, LCommaPos - 1);
        LHTTPMethod := LHTTPMethod.Trim;
        // Strip 'http' prefix from enum name to get bare 'GET', 'POST', etc.
        if LHTTPMethod.StartsWith('http', True) then
          LHTTPMethod := LHTTPMethod.Substring(4).ToUpper;

        LToolName := PathToToolName(LHTTPMethod, LFullPath);

        // Collision detection
        if LSeenNames.ContainsKey(LToolName) then
        begin
          LPrefixedName := CamelToSnake(LRttiType.Name) + '_' + LToolName;
          if LSeenNames.ContainsKey(LPrefixedName) then
            raise EMCPBridgeException.CreateFmt(
              'MCPBridge: duplicate tool name "%s" (prefixed: "%s") is already taken. ' +
              'Conflicting actions: %s and %s.%s',
              [LToolName, LPrefixedName,
               LSeenNames[LToolName],
               LRttiType.Name, LMethod.Name]);
          LToolName := LPrefixedName;
        end;

        LRoute := TMCPBridgeRouteInfo.Create;
        try
          LRoute.ToolName            := LToolName;
          LRoute.HTTPMethod          := LHTTPMethod;
          LRoute.PathTemplate        := LFullPath;
          LRoute.ControllerClassName := LRttiType.Name;
          if LDocAttr <> nil then
            LRoute.Description := LDocAttr.Value
          else
            LRoute.Description := '';

          for LParam in LMethod.GetParameters do
          begin
            if LParam.ParamType = nil then Continue;

            LFromQuery := nil;
            LFromBody  := nil;

            for LParamAttr in LParam.GetAttributes do
            begin
              if LParamAttr is MVCFromQueryStringAttribute then
                LFromQuery := MVCFromQueryStringAttribute(LParamAttr)
              else if LParamAttr is MVCFromBodyAttribute then
                LFromBody := MVCFromBodyAttribute(LParamAttr);
            end;

            // Detect path parameter: ($name) or ($name:type) form
            LParamSegment := '($' + LParam.Name;
            LIsPathParam := Pos(LParamSegment + ')', LFullPath) > 0;
            if not LIsPathParam then
              LIsPathParam := Pos(LParamSegment + ':', LFullPath) > 0;

            if (not LIsPathParam) and (LFromQuery = nil) and (LFromBody = nil) then
              Continue;

            LBridgeParam.TypeKind       := LParam.ParamType.TypeKind;
            LBridgeParam.JsonSchemaType := DelphiTypeToJsonSchema(LParam.ParamType.Handle);

            if LIsPathParam then
            begin
              LBridgeParam.Name        := LParam.Name;
              LBridgeParam.Kind        := bpkPath;
              LBridgeParam.Required    := True;
              LBridgeParam.Description := 'Path parameter: ' + LBridgeParam.Name;
            end
            else if LFromQuery <> nil then
            begin
              LBridgeParam.Name        := LFromQuery.ParamName;
              LBridgeParam.Kind        := bpkQuery;
              LBridgeParam.Required    := not LFromQuery.CanBeUsedADefaultValue;
              LBridgeParam.Description := 'Query parameter: ' + LBridgeParam.Name;
            end
            else
            begin
              LBridgeParam.Name           := 'body';
              LBridgeParam.Kind           := bpkBody;
              LBridgeParam.Required       := True;
              LBridgeParam.TypeKind       := tkUString;
              LBridgeParam.JsonSchemaType := 'string';
              LBridgeParam.Description    := 'Request body (JSON)';
            end;

            LRoute.Params := LRoute.Params + [LBridgeParam];
          end;

          Result := Result + [LRoute];
          LSeenNames.Add(LToolName, LRttiType.Name + '.' + LMethod.Name);
        except
          LRoute.Free;
          raise;
        end;
      end;
    end;
  finally
    LSeenNames.Free;
    LCtx.Free;
  end;
end;

{ TMCPBridgeProvider }

constructor TMCPBridgeProvider.Create(const ABaseURL: string);
begin
  inherited Create;
  FBaseURL := ABaseURL;
  FRoutes := TObjectList<TMCPBridgeRouteInfo>.Create(True);
  FHttpClient := THTTPClient.Create;
  FHttpClient.ContentType := 'application/json';
  FHttpClient.Accept := 'application/json';
end;

destructor TMCPBridgeProvider.Destroy;
begin
  FHttpClient.Free;
  FRoutes.Free;
  inherited;
end;

procedure TMCPBridgeProvider.AddRoute(ARoute: TMCPBridgeRouteInfo);
begin
  FRoutes.Add(ARoute);
end;

function TMCPBridgeProvider.FindRoute(const AToolName: string): TMCPBridgeRouteInfo;
var
  LRoute: TMCPBridgeRouteInfo;
begin
  for LRoute in FRoutes do
    if SameText(LRoute.ToolName, AToolName) then
      Exit(LRoute);
  Result := nil;
end;

function TMCPBridgeProvider.BuildURL(ARoute: TMCPBridgeRouteInfo; AArguments: TJDOJsonObject): string;
var
  LPath: string;
  LParam: TMCPBridgeParamInfo;
  LValue: string;
  LTypedPat: string;
  LStart, LEnd: Integer;
begin
  LPath := ARoute.PathTemplate;
  for LParam in ARoute.Params do
  begin
    if LParam.Kind = bpkPath then
    begin
      LValue := '';
      if (AArguments <> nil) and AArguments.Contains(LParam.Name) then
        LValue := AArguments.S[LParam.Name];
      var LEncoded := TNetEncoding.URL.Encode(LValue).Replace('+', '%20', [rfReplaceAll]);
      LPath := StringReplace(LPath, '($' + LParam.Name + ')', LEncoded, [rfIgnoreCase]);
      LTypedPat := '($' + LParam.Name + ':';
      LStart := Pos(LTypedPat, LPath);
      if LStart > 0 then
      begin
        LEnd := Pos(')', LPath, LStart);
        if LEnd > LStart then
          LPath := Copy(LPath, 1, LStart - 1) + LEncoded + Copy(LPath, LEnd + 1, MaxInt);
      end;
    end;
  end;
  Result := FBaseURL + LPath;
end;

function TMCPBridgeProvider.BuildQueryString(ARoute: TMCPBridgeRouteInfo; AArguments: TJDOJsonObject): string;
var
  LParam: TMCPBridgeParamInfo;
  LSB: TStringBuilder;
  LValue: string;
begin
  LSB := TStringBuilder.Create;
  try
    for LParam in ARoute.Params do
    begin
      if LParam.Kind <> bpkQuery then Continue;
      if (AArguments = nil) or not AArguments.Contains(LParam.Name) then Continue;
      LValue := AArguments.S[LParam.Name];
      if LSB.Length = 0 then LSB.Append('?') else LSB.Append('&');
      LSB.Append(TNetEncoding.URL.Encode(LParam.Name).Replace('+', '%20', [rfReplaceAll]));
      LSB.Append('=');
      LSB.Append(TNetEncoding.URL.Encode(LValue).Replace('+', '%20', [rfReplaceAll]));
    end;
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

function TMCPBridgeProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;
var
  LRoute: TMCPBridgeRouteInfo;
  LDef: TMCPDynamicToolDef;
  LDefs: TArray<TMCPDynamicToolDef>;
  I, J: Integer;
begin
  SetLength(LDefs, FRoutes.Count);
  for I := 0 to FRoutes.Count - 1 do
  begin
    LRoute := FRoutes[I];
    LDef.Name                := LRoute.ToolName;
    LDef.Description         := LRoute.Description;
    LDef.ControllerClassName := LRoute.ControllerClassName;
    SetLength(LDef.Params, Length(LRoute.Params));
    for J := 0 to High(LRoute.Params) do
    begin
      LDef.Params[J].Name           := LRoute.Params[J].Name;
      LDef.Params[J].Description    := LRoute.Params[J].Description;
      LDef.Params[J].Required       := LRoute.Params[J].Required;
      LDef.Params[J].TypeKind       := LRoute.Params[J].TypeKind;
      LDef.Params[J].JsonSchemaType := LRoute.Params[J].JsonSchemaType;
    end;
    LDefs[I] := LDef;
  end;
  Result := LDefs;
end;

function TMCPBridgeProvider.InvokeDynamic(const AToolName: string; AArguments: TJDOJsonObject): TMCPToolResult;
var
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

  LURL := BuildURL(LRoute, AArguments) + BuildQueryString(LRoute, AArguments);

  LHasBody := False;
  LBodyContent := '';
  for LParam in LRoute.Params do
    if LParam.Kind = bpkBody then
    begin
      LHasBody := True;
      if (AArguments <> nil) and AArguments.Contains(LParam.Name) then
        LBodyContent := AArguments.S[LParam.Name];
      Break;
    end;

  LBodyStream := nil;
  if LHasBody then
    LBodyStream := TStringStream.Create(LBodyContent, TEncoding.UTF8);
  try
    try
      if SameText(LRoute.HTTPMethod, 'GET') then
        LResp := FHttpClient.Get(LURL)
      else if SameText(LRoute.HTTPMethod, 'DELETE') then
        LResp := FHttpClient.Delete(LURL)
      else if SameText(LRoute.HTTPMethod, 'POST') then
        LResp := FHttpClient.Post(LURL, LBodyStream)
      else if SameText(LRoute.HTTPMethod, 'PUT') then
        LResp := FHttpClient.Put(LURL, LBodyStream)
      else if SameText(LRoute.HTTPMethod, 'PATCH') then
        LResp := FHttpClient.Patch(LURL, LBodyStream)
      else
        LResp := FHttpClient.Get(LURL);

      if LResp.StatusCode < 400 then
        Result := TMCPToolResult.Text(LResp.ContentAsString(TEncoding.UTF8))
      else
        Result := TMCPToolResult.Error(
          'HTTP ' + LResp.StatusCode.ToString + ': ' + LResp.ContentAsString(TEncoding.UTF8));
    except
      on E: Exception do
        Result := TMCPToolResult.Error('Network error: ' + E.Message);
    end;
  finally
    LBodyStream.Free;
  end;
end;

{ TMCPBridgeCodeGen }

constructor TMCPBridgeCodeGen.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
end;

function TMCPBridgeCodeGen.ToolNameToMethodName(const AToolName: string): string;
var
  LParts: TArray<string>;
  LSB: TStringBuilder;
  LPart: string;
begin
  LParts := AToolName.Split(['_']);
  LSB := TStringBuilder.Create;
  try
    for LPart in LParts do
      if not LPart.IsEmpty then
        LSB.Append(UpperCase(Copy(LPart, 1, 1)) + Copy(LPart, 2, MaxInt));
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

function TMCPBridgeCodeGen.ToolNameToProviderName(const AControllerClassName: string): string;
var
  LName: string;
begin
  LName := AControllerClassName;
  if LName.StartsWith('T') then LName := LName.Substring(1);
  if LName.EndsWith('Controller') then
    LName := LName.Substring(0, Length(LName) - Length('Controller'));
  Result := 'T' + LName + 'MCPProvider';
end;

procedure TMCPBridgeCodeGen.WriteProviderFile(const AOutputPath, AControllerClassName: string; ARoutes: TArray<TMCPBridgeRouteInfo>);
var
  LFileName, LProviderName, LUnitName: string;
  LSB: TStringBuilder;
  LRoute: TMCPBridgeRouteInfo;
  LParam: TMCPBridgeParamInfo;
  LFirst: Boolean;
  LDate, LURLExpr, LQuerySep: string;
  LHasBody: Boolean;
  LBodyParamName: string;
begin
  LProviderName := ToolNameToProviderName(AControllerClassName);
  LUnitName := 'MCP' + AControllerClassName;
  if LUnitName.EndsWith('Controller') then
    LUnitName := LUnitName.Substring(0, Length(LUnitName) - Length('Controller'));
  LUnitName := LUnitName + 'ProviderU';
  LFileName := IncludeTrailingPathDelimiter(AOutputPath) + LUnitName + '.pas';
  LDate := FormatDateTime('yyyy-mm-dd', Now);

  LSB := TStringBuilder.Create;
  try
    LSB.AppendLine('// *** GENERATED ' + LDate + ' — REVIEW AND CURATE BEFORE PRODUCTION USE ***');
    LSB.AppendLine('// Source: ' + AControllerClassName);
    LSB.AppendLine('// Generator: MVCFramework.MCP.Bridge / GenerateProviderUnit');
    LSB.AppendLine('');
    LSB.AppendLine('unit ' + LUnitName + ';');
    LSB.AppendLine('');
    LSB.AppendLine('interface');
    LSB.AppendLine('');
    LSB.AppendLine('uses');
    LSB.AppendLine('  MVCFramework.MCP.ToolProvider, MVCFramework.MCP.Attributes,');
    LSB.AppendLine('  MVCFramework.MCP.Server, System.Net.HttpClient,');
    LSB.AppendLine('  System.Classes, System.SysUtils, System.NetEncoding;');
    LSB.AppendLine('');
    LSB.AppendLine('type');
    LSB.AppendLine('  ' + LProviderName + ' = class(TMCPToolProvider)');
    LSB.AppendLine('  private');
    LSB.AppendLine('    FBaseURL: string;');
    LSB.AppendLine('  public');
    LSB.AppendLine('    constructor Create; override;');
    LSB.AppendLine('');

    if Length(ARoutes) = 0 then
      LSB.AppendLine('    // No bridge tools registered');

    for LRoute in ARoutes do
    begin
      if LRoute.Description.IsEmpty then
        LSB.AppendLine('    // TODO: add description (no [MVCDoc] found on action)');
      LSB.AppendLine('    [MCPTool(''' + LRoute.ToolName + ''', ''' +
        StringReplace(LRoute.Description, '''', '''''', [rfReplaceAll]) + ''')]');
      LSB.Append('    function ' + ToolNameToMethodName(LRoute.ToolName) + '(');
      LFirst := True;
      for LParam in LRoute.Params do
      begin
        if not LFirst then LSB.Append(';');
        LSB.AppendLine('');
        if LParam.TypeKind = tkFloat then
          LSB.AppendLine('      // TODO: verify JSON schema type for parameter ''' + LParam.Name + '''');
        LSB.Append('      [MCPParam(''' + LParam.Description + '''');
        if not LParam.Required then LSB.Append(', False');
        LSB.Append(')] const ' + LParam.Name + ': ');
        case LParam.TypeKind of
          tkInteger: LSB.Append('Integer');
          tkInt64:   LSB.Append('Int64');
          tkFloat:   LSB.Append('Double');
          tkEnumeration: LSB.Append('Boolean');
        else
          LSB.Append('string');
        end;
        LFirst := False;
      end;
      LSB.AppendLine('');
      LSB.AppendLine('    ): TMCPToolResult;');
      LSB.AppendLine('');
    end;

    LSB.AppendLine('  end;');
    LSB.AppendLine('');
    LSB.AppendLine('implementation');
    LSB.AppendLine('');
    LSB.AppendLine('constructor ' + LProviderName + '.Create;');
    LSB.AppendLine('begin');
    LSB.AppendLine('  inherited;');
    LSB.AppendLine('  FBaseURL := ''http://localhost:8080''; // TODO: move to config / .env');
    LSB.AppendLine('end;');
    LSB.AppendLine('');

    for LRoute in ARoutes do
    begin
      LSB.AppendLine('function ' + LProviderName + '.' +
        ToolNameToMethodName(LRoute.ToolName) + '(');
      LFirst := True;
      for LParam in LRoute.Params do
      begin
        if not LFirst then LSB.AppendLine(';');
        LSB.Append('  const ' + LParam.Name + ': ');
        case LParam.TypeKind of
          tkInteger: LSB.Append('Integer');
          tkInt64:   LSB.Append('Int64');
          tkFloat:   LSB.Append('Double');
          tkEnumeration: LSB.Append('Boolean');
        else LSB.Append('string');
        end;
        LFirst := False;
      end;
      LSB.AppendLine('');
      LSB.AppendLine('): TMCPToolResult;');
      LSB.AppendLine('var');
      LSB.AppendLine('  LClient: THTTPClient;');
      LSB.AppendLine('  LResp: IHTTPResponse;');
      LSB.AppendLine('  LURL: string;');

      LHasBody := False;
      LBodyParamName := '';
      for LParam in LRoute.Params do
        if LParam.Kind = bpkBody then
        begin
          LHasBody := True;
          LBodyParamName := LParam.Name;
          Break;
        end;
      if LHasBody then
        LSB.AppendLine('  LBodyStream: TStringStream;');

      LSB.AppendLine('begin');
      if LHasBody then
        LSB.AppendLine('  LBodyStream := nil;');
      LSB.AppendLine('  LClient := THTTPClient.Create;');

      LURLExpr := 'FBaseURL + ''' + LRoute.PathTemplate + '''';
      for LParam in LRoute.Params do
        if LParam.Kind = bpkPath then
        begin
          LURLExpr := StringReplace(LURLExpr,
            '($' + LParam.Name + ')',
            '''+' + LParam.Name + '.ToString+''',
            [rfReplaceAll, rfIgnoreCase]);
          // Also handle typed form ($name:type)
          var LTypedPat := LowerCase('($' + LParam.Name + ':');
          var LURLLower := LowerCase(LURLExpr);
          var LTypedStart := Pos(LTypedPat, LURLLower);
          if LTypedStart > 0 then
          begin
            var LClosePos := Pos(')', LURLExpr, LTypedStart);
            if LClosePos > 0 then
              LURLExpr := Copy(LURLExpr, 1, LTypedStart - 1) +
                '''+' + LParam.Name + '.ToString+''' +
                Copy(LURLExpr, LClosePos + 1, MaxInt);
          end;
        end;
      LQuerySep := '?';
      for LParam in LRoute.Params do
        if LParam.Kind = bpkQuery then
        begin
          if LParam.TypeKind = tkEnumeration then
            LURLExpr := LURLExpr + '+''' + LQuerySep + LParam.Name + '=''+' +
              LParam.Name + '.ToString.ToLower'
          else
            LURLExpr := LURLExpr + '+''' + LQuerySep + LParam.Name + '=''+' +
              LParam.Name + '.ToString';
          LQuerySep := '&';
        end;

      LSB.AppendLine('  LURL := ' + LURLExpr + ';');

      LSB.AppendLine('  try');
      if LHasBody then
        LSB.AppendLine('    LBodyStream := TStringStream.Create(' +
          LBodyParamName + ', TEncoding.UTF8);');
      if LHasBody then
      begin
        if SameText(LRoute.HTTPMethod, 'PUT') then
          LSB.AppendLine('    LResp := LClient.Put(LURL, LBodyStream);')
        else if SameText(LRoute.HTTPMethod, 'PATCH') then
          LSB.AppendLine('    LResp := LClient.Patch(LURL, LBodyStream);')
        else
          LSB.AppendLine('    LResp := LClient.Post(LURL, LBodyStream);');
      end
      else
      begin
        if SameText(LRoute.HTTPMethod, 'DELETE') then
          LSB.AppendLine('    LResp := LClient.Delete(LURL);')
        else
          LSB.AppendLine('    LResp := LClient.Get(LURL);');
      end;

      LSB.AppendLine('    if LResp.StatusCode < 400 then');
      LSB.AppendLine('      Result := TMCPToolResult.Text(LResp.ContentAsString(TEncoding.UTF8))');
      LSB.AppendLine('    else');
      LSB.AppendLine('      Result := TMCPToolResult.Error(');
      LSB.AppendLine('        ''HTTP '' + LResp.StatusCode.ToString + '': '' + LResp.ContentAsString(TEncoding.UTF8));');
      LSB.AppendLine('  finally');
      if LHasBody then
        LSB.AppendLine('    LBodyStream.Free;');
      LSB.AppendLine('    LClient.Free;');
      LSB.AppendLine('  end;');
      LSB.AppendLine('end;');
      LSB.AppendLine('');
    end;

    LSB.AppendLine('initialization');
    LSB.AppendLine('  TMCPServer.Instance.RegisterToolProvider(' + LProviderName + ');');
    LSB.AppendLine('');
    LSB.AppendLine('end.');

    TFile.WriteAllText(LFileName, LSB.ToString, TEncoding.UTF8);
  finally
    LSB.Free;
  end;
end;

procedure TMCPBridgeCodeGen.GenerateAll(const AOutputPath: string);
var
  LByController: TDictionary<string, TList<TMCPBridgeRouteInfo>>;
  LDynProvider: TMCPToolProvider;
  LBridgeProvider: TMCPBridgeProvider;
  LRoute: TMCPBridgeRouteInfo;
  LGroup: TList<TMCPBridgeRouteInfo>;
  LPair: TPair<string, TList<TMCPBridgeRouteInfo>>;
  LRoutesArray: TArray<TMCPBridgeRouteInfo>;
  I: Integer;
begin
  LByController := TDictionary<string, TList<TMCPBridgeRouteInfo>>.Create;
  try
    for LDynProvider in FServer.DynamicProviders do
    begin
      if not (LDynProvider is TMCPBridgeProvider) then Continue;
      LBridgeProvider := TMCPBridgeProvider(LDynProvider);
      for LRoute in LBridgeProvider.Routes do
      begin
        if not LByController.TryGetValue(LRoute.ControllerClassName, LGroup) then
        begin
          LGroup := TList<TMCPBridgeRouteInfo>.Create;
          LByController.Add(LRoute.ControllerClassName, LGroup);
        end;
        LGroup.Add(LRoute);
      end;
    end;

    for LPair in LByController do
    begin
      SetLength(LRoutesArray, LPair.Value.Count);
      for I := 0 to LPair.Value.Count - 1 do
        LRoutesArray[I] := LPair.Value[I];
      WriteProviderFile(AOutputPath, LPair.Key, LRoutesArray);
    end;
  finally
    for LPair in LByController do
      LPair.Value.Free;
    LByController.Free;
  end;
end;

{ TMCPServerBridgeHelper }

procedure TMCPServerBridgeHelper.RegisterFromEngine(AEngine: TMVCEngine; const ABaseURL: string);
var
  LScanner: TMCPEngineScanner;
  LRoutes: TArray<TMCPBridgeRouteInfo>;
  LProvider: TMCPBridgeProvider;
  LRoute: TMCPBridgeRouteInfo;
begin
  if ABaseURL.IsEmpty then
    raise EMCPBridgeException.Create(
      'MCPBridge.RegisterFromEngine: ABaseURL must not be empty');

  LScanner := TMCPEngineScanner.Create(AEngine);
  try
    LRoutes := LScanner.Scan;
  finally
    LScanner.Free;
  end;

  LProvider := TMCPBridgeProvider.Create(ABaseURL);
  try
    for LRoute in LRoutes do
      LProvider.AddRoute(LRoute);
    // TMCPServer takes ownership of LProvider (and transitively of the routes inside it)
    Self.RegisterDynamicProvider(LProvider);
  except
    LProvider.Free;
    raise;
  end;

  if not Self.ServerName.Contains('[bootstrap proxy') then
    Self.ServerName := Self.ServerName + ' [bootstrap proxy — not for production]';
end;

procedure TMCPServerBridgeHelper.GenerateProviderUnit(const AOutputPath: string);
var
  LCodeGen: TMCPBridgeCodeGen;
begin
  if not DirectoryExists(AOutputPath) then
    raise EMCPBridgeException.CreateFmt(
      'MCPBridge.GenerateProviderUnit: output directory not found: %s', [AOutputPath]);

  LCodeGen := TMCPBridgeCodeGen.Create(Self);
  try
    LCodeGen.GenerateAll(AOutputPath);
  finally
    LCodeGen.Free;
  end;
end;

end.
