# MCPBridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `MVCFramework.MCP.Bridge.pas` — a two-phase feature that auto-registers a DMVCFramework engine's REST endpoints as MCP tools (bootstrap proxy), then can emit `.pas` provider files ready for manual curation.

**Architecture:** A `TMCPServerBridgeHelper` class helper adds `RegisterFromEngine` and `GenerateProviderUnit` to `TMCPServer`. `RegisterFromEngine` creates a `TMCPBridgeProvider` that scans the engine via RTTI and proxies tool calls via HTTP to localhost. `GenerateProviderUnit` emits one `.pas` file per controller from the current registry. Minimal backwards-compatible hooks are added to `TMCPToolProvider` and `TMCPServer` to support instance-based (non-RTTI) dispatch.

**Tech Stack:** Object Pascal / Delphi 11+, DMVCFramework, JsonDataObjects, System.Net.HttpClient, System.Rtti

---

## File Map

| File | Change |
|---|---|
| `sources/MVCFramework.MCP.ToolProvider.pas` | Add `TMCPDynamicParamDef`, `TMCPDynamicToolDef`, `GetDynamicToolDefs`, `InvokeDynamic` virtual methods |
| `sources/MVCFramework.MCP.Server.pas` | Add `HandlerInstance` to `TMCPToolInfo`, `FDynamicProviders` list + `RegisterDynamicProvider` to `TMCPServer` |
| `sources/MVCFramework.MCP.RequestHandler.pas` | Add `HandlerInstance` branch in `DoToolsCall` |
| `sources/MVCFramework.MCP.Bridge.pas` | **NEW** — scanner, provider, code gen, class helper |
| `tests/testproject/MCPBridgeTestControllerU.pas` | **NEW** — test REST controller for bridge integration |
| `tests/testproject/EngineConfigU.pas` | Add `RegisterFromEngine` call |
| `tests/clientproject/MCPClientTest.dpr` | Add `TestBridge` procedure |

---

## Task 1: Add dynamic dispatch types to TMCPToolProvider

**Files:**
- Modify: `sources/MVCFramework.MCP.ToolProvider.pas`

- [ ] **Step 1: Add types and virtual methods to the interface section**

In `MVCFramework.MCP.ToolProvider.pas`, add after the existing type declarations (before `TMCPToolProvider = class`):

```pascal
  { Lightweight parameter descriptor for dynamically-registered tools.
    The scanner pre-computes JsonSchemaType to avoid needing PTypeInfo at
    registration time (which TMCPServer.RegisterDynamicProvider doesn't have). }
  TMCPDynamicParamDef = record
    Name: string;
    Description: string;
    Required: Boolean;
    TypeKind: TTypeKind;
    JsonSchemaType: string;
  end;

  { Tool descriptor for dynamically-registered tools (no RTTI method). }
  TMCPDynamicToolDef = record
    Name: string;
    Description: string;
    ControllerClassName: string; // for code-gen grouping
    Params: TArray<TMCPDynamicParamDef>;
  end;
```

Then add two virtual methods to `TMCPToolProvider`:

```pascal
  TMCPToolProvider = class
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { Override to return tool definitions for dynamic (non-RTTI) registration.
      Default returns empty — existing providers are unaffected. }
    function GetDynamicToolDefs: TArray<TMCPDynamicToolDef>; virtual;

    { Override to handle invocation for dynamic tools.
      Called by DoToolsCall when TMCPToolInfo.HandlerInstance is set.
      Default raises Exception('not implemented'). }
    function InvokeDynamic(const AToolName: string;
      AArguments: TJDOJsonObject): TMCPToolResult; virtual;
  end;
```

- [ ] **Step 2: Add stub implementations in the implementation section**

```pascal
function TMCPToolProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;
begin
  Result := nil;
end;

function TMCPToolProvider.InvokeDynamic(const AToolName: string;
  AArguments: TJDOJsonObject): TMCPToolResult;
begin
  raise Exception.Create('InvokeDynamic not implemented');
end;
```

- [ ] **Step 3: Compile to verify no breaks**

```
dcc32.exe sources/MVCFramework.MCP.ToolProvider.pas
```

Expected: compiles without errors or warnings.

- [ ] **Step 4: Commit**

```bash
git add sources/MVCFramework.MCP.ToolProvider.pas
git commit -m "feat(bridge): add GetDynamicToolDefs/InvokeDynamic virtual hooks to TMCPToolProvider"
```

---

## Task 2: Extend TMCPToolInfo and TMCPServer for instance-based providers

**Files:**
- Modify: `sources/MVCFramework.MCP.Server.pas`

- [ ] **Step 1: Add HandlerInstance field to TMCPToolInfo**

In the `TMCPToolInfo = class` declaration, add:

```pascal
  TMCPToolInfo = class
  public
    Name: string;
    Description: string;
    ProviderClass: TMCPToolProviderClass;
    RttiMethod: TRttiMethod;
    Params: TArray<TMCPParamInfo>;
    InputSchema: TJDOJsonObject;
    { Non-nil for dynamic tools (bridge proxy). When set, DoToolsCall calls
      HandlerInstance.InvokeDynamic instead of RTTI dispatch. Not owned here —
      ownership is in TMCPServer.FDynamicProviders. }
    HandlerInstance: TMCPToolProvider;
    destructor Destroy; override;
  end;
```

- [ ] **Step 2: Add FDynamicProviders list and RegisterDynamicProvider to TMCPServer**

In the `TMCPServer = class` private section, add:

```pascal
    FDynamicProviders: TObjectList<TMCPToolProvider>;
```

In the public section, add:

```pascal
    { Registers a pre-built provider instance. Tools come from
      AProvider.GetDynamicToolDefs. TMCPServer takes ownership of AProvider. }
    procedure RegisterDynamicProvider(AProvider: TMCPToolProvider);

    { Read-only access to dynamic providers — used by TMCPBridgeCodeGen. }
    property DynamicProviders: TObjectList<TMCPToolProvider> read FDynamicProviders;
```

- [ ] **Step 3: Implement the constructor/destructor changes**

In `TMCPServer.Create`:
```pascal
  FDynamicProviders := TObjectList<TMCPToolProvider>.Create(True); // owns objects
```

In `TMCPServer.Destroy`:
```pascal
  FDynamicProviders.Free;
```

Add to uses in implementation section (if not already present):
```pascal
  System.Generics.Collections,
```

- [ ] **Step 4: Implement RegisterDynamicProvider**

```pascal
procedure TMCPServer.RegisterDynamicProvider(AProvider: TMCPToolProvider);
var
  LDefs: TArray<TMCPDynamicToolDef>;
  LDef: TMCPDynamicToolDef;
  LToolInfo: TMCPToolInfo;
  I: Integer;
  LKey: string;
  LParamInfo: TMCPParamInfo;
begin
  LDefs := AProvider.GetDynamicToolDefs;
  for LDef in LDefs do
  begin
    LToolInfo := TMCPToolInfo.Create;
    try
      LToolInfo.Name := LDef.Name;
      LToolInfo.Description := LDef.Description;
      LToolInfo.ProviderClass := nil;
      LToolInfo.RttiMethod := nil;
      LToolInfo.HandlerInstance := AProvider;

      SetLength(LToolInfo.Params, Length(LDef.Params));
      for I := 0 to High(LDef.Params) do
      begin
        LParamInfo.Name         := LDef.Params[I].Name;
        LParamInfo.Description  := LDef.Params[I].Description;
        LParamInfo.Required     := LDef.Params[I].Required;
        LParamInfo.TypeKind     := LDef.Params[I].TypeKind;
        LParamInfo.JsonSchemaType := LDef.Params[I].JsonSchemaType;
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
    LogI('MCP: Registered dynamic tool "' + LDef.Name + '"');
  end;
  FDynamicProviders.Add(AProvider); // take ownership
end;
```

- [ ] **Step 5: Compile test project to verify no breaks**

```
dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin
```

Expected: compiles, existing tools/resources/prompts still registered correctly.

- [ ] **Step 6: Commit**

```bash
git add sources/MVCFramework.MCP.Server.pas
git commit -m "feat(bridge): extend TMCPServer with RegisterDynamicProvider and HandlerInstance"
```

---

## Task 3: Wire dynamic dispatch in DoToolsCall

**Files:**
- Modify: `sources/MVCFramework.MCP.RequestHandler.pas`

- [ ] **Step 1: Add HandlerInstance branch in DoToolsCall**

Locate the end of `DoToolsCall`, after the required param validation loop and before `SetLength(LArgs, ...)`. Replace the block from `SetLength` to the end of the function body with:

```pascal
  { Dynamic dispatch (bridge/proxy tools) }
  if LToolInfo.HandlerInstance <> nil then
  begin
    LToolResult := LToolInfo.HandlerInstance.InvokeDynamic(LToolInfo.Name, LArguments);
    Result := LToolResult.ToJSON;
    Exit;
  end;

  { RTTI dispatch (attribute-decorated tool methods) }
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
```

- [ ] **Step 2: Compile and run existing client test to verify no regressions**

```
dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin
dcc32.exe tests/clientproject/MCPClientTest.dpr -Etests/clientproject/bin
```

Start the test server, then run:
```
tests/clientproject/bin/MCPClientTest.exe
```

Expected: all existing PASS lines still pass.

- [ ] **Step 3: Commit**

```bash
git add sources/MVCFramework.MCP.RequestHandler.pas
git commit -m "feat(bridge): add HandlerInstance dynamic dispatch branch in DoToolsCall"
```

---

## Task 4: Create MVCFramework.MCP.Bridge.pas — scaffold

**Files:**
- Create: `sources/MVCFramework.MCP.Bridge.pas`

- [ ] **Step 1: Write the file skeleton**

```pascal
// ***************************************************************************
// MCP Server Library for DMVCFramework
// Copyright (c) 2010-2026 Daniele Teti
// Licensed under the Apache License, Version 2.0
// ***************************************************************************

unit MVCFramework.MCP.Bridge;

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections, System.RegularExpressions,
  System.Net.HttpClient, System.Net.URLClient,
  JsonDataObjects,
  MVCFramework, MVCFramework.Commons,
  MVCFramework.MCP.Server, MVCFramework.MCP.ToolProvider,
  MVCFramework.MCP.Types;

type
  EMCPBridgeException = class(Exception);

  { Source of a bridge parameter — controls URL construction at invocation. }
  TMCPBridgeParamKind = (bpkPath, bpkQuery, bpkBody);

  TMCPBridgeParamInfo = record
    Name: string;            // MCP param name (also used in URL substitution)
    Kind: TMCPBridgeParamKind;
    Description: string;
    Required: Boolean;
    TypeKind: TTypeKind;
    JsonSchemaType: string;
  end;

  { One REST action → one MCP tool. }
  TMCPBridgeRouteInfo = class
  public
    ToolName: string;
    Description: string;
    HTTPMethod: string;       // 'GET', 'POST', 'PUT', 'DELETE', 'PATCH'
    PathTemplate: string;     // e.g. '/customers/{id}'
    ControllerClassName: string;
    Params: TArray<TMCPBridgeParamInfo>;
  end;

  { RTTI scan of TMVCEngine → TArray<TMCPBridgeRouteInfo>. }
  TMCPEngineScanner = class
  private
    class function CamelToSnake(const AName: string): string;
    class function PlaceholderToSnake(const APlaceholder: string): string;
    class function PathToToolName(const AHTTPMethod, APath: string): string;
    class function DelphiTypeKindToJsonSchema(AKind: TTypeKind): string;
    class function ResolveMVCFromParamName(ARttiParam: TRttiParameter;
      const AAttrName: string): string;
  public
    class function Scan(AEngine: TMVCEngine): TObjectList<TMCPBridgeRouteInfo>;
  end;

  { Runtime HTTP proxy tool provider. One instance per RegisterFromEngine call. }
  TMCPBridgeProvider = class(TMCPToolProvider)
  private
    FBaseURL: string;
    FRoutes: TObjectList<TMCPBridgeRouteInfo>;
    FHTTPClient: TNetHTTPClient;
    function BuildURL(ARoute: TMCPBridgeRouteInfo;
      AArguments: TJDOJsonObject): string;
    function BuildQueryString(ARoute: TMCPBridgeRouteInfo;
      AArguments: TJDOJsonObject): string;
    function FindRoute(const AToolName: string): TMCPBridgeRouteInfo;
  public
    constructor Create(ARoutes: TObjectList<TMCPBridgeRouteInfo>;
      const ABaseURL: string); reintroduce;
    destructor Destroy; override;
    function GetDynamicToolDefs: TArray<TMCPDynamicToolDef>; override;
    function InvokeDynamic(const AToolName: string;
      AArguments: TJDOJsonObject): TMCPToolResult; override;
    { Read-only access used by TMCPBridgeCodeGen.GenerateAll }
    property Routes: TObjectList<TMCPBridgeRouteInfo> read FRoutes;
  end;

  { Emits one .pas file per controller from the current TMCPServer registry. }
  TMCPBridgeCodeGen = class
  private
    FServer: TMCPServer;
    class function ToolNameToMethodName(const AToolName: string): string;
    class function ToolNameToProviderName(const AControllerClass: string): string;
    procedure WriteProviderFile(const AOutputPath, AControllerClass: string;
      ARoutes: TObjectList<TMCPBridgeRouteInfo>);
  public
    constructor Create(AServer: TMCPServer);
    procedure GenerateAll(const AOutputPath: string);
  end;

  { Class helper — adds bridge methods to TMCPServer without touching Server.pas. }
  TMCPServerBridgeHelper = class helper for TMCPServer
    procedure RegisterFromEngine(AEngine: TMVCEngine; const ABaseURL: string);
    procedure GenerateProviderUnit(const AOutputPath: string);
  end;

implementation

// ... (implementations in subsequent tasks)

end.
```

- [ ] **Step 2: Compile the skeleton to check type/unit references**

```
dcc32.exe sources/MVCFramework.MCP.Bridge.pas
```

Expected: may fail on missing `implementation` bodies — that is fine. What must pass: unit references resolve, type declarations are syntactically valid.

- [ ] **Step 3: Commit**

```bash
git add sources/MVCFramework.MCP.Bridge.pas
git commit -m "feat(bridge): add MVCFramework.MCP.Bridge.pas scaffold"
```

---

## Task 5: Implement tool name generation utilities

**Files:**
- Modify: `sources/MVCFramework.MCP.Bridge.pas` (implementation section)

- [ ] **Step 1: Implement CamelToSnake**

```pascal
class function TMCPEngineScanner.CamelToSnake(const AName: string): string;
var
  I: Integer;
  C: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 1 to Length(AName) do
    begin
      C := AName[I];
      if C.IsUpper and (I > 1) then
        SB.Append('_');
      SB.Append(C.ToLower);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;
```

- [ ] **Step 2: Implement PlaceholderToSnake**

Converts `{customerId}` → `by_customer_id`:

```pascal
class function TMCPEngineScanner.PlaceholderToSnake(const APlaceholder: string): string;
begin
  // APlaceholder is already stripped of braces by PathToToolName
  Result := 'by_' + CamelToSnake(APlaceholder);
end;
```

- [ ] **Step 3: Implement PathToToolName**

```pascal
class function TMCPEngineScanner.PathToToolName(const AHTTPMethod,
  APath: string): string;
var
  LPath: string;
  I: Integer;
  LParts: TArray<string>;
  LSegment: string;
  SB: TStringBuilder;
begin
  // Remove leading slash
  LPath := APath;
  if LPath.StartsWith('/') then
    LPath := LPath.Substring(1);

  LParts := LPath.Split(['/']);

  SB := TStringBuilder.Create;
  try
    SB.Append(LowerCase(AHTTPMethod));
    for LSegment in LParts do
    begin
      if LSegment.IsEmpty then
        Continue;
      SB.Append('_');
      if LSegment.StartsWith('{') and LSegment.EndsWith('}') then
      begin
        // placeholder: {customerId} → by_customer_id
        LPath := LSegment.Substring(1, Length(LSegment) - 2);
        SB.Append(PlaceholderToSnake(LPath));
      end
      else
        SB.Append(LowerCase(LSegment));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;
```

- [ ] **Step 4: Implement DelphiTypeKindToJsonSchema**

```pascal
class function TMCPEngineScanner.DelphiTypeKindToJsonSchema(AKind: TTypeKind): string;
begin
  case AKind of
    tkUString, tkString, tkLString, tkWString, tkChar, tkWChar:
      Result := 'string';
    tkInteger, tkInt64:
      Result := 'integer';
    tkFloat:
      Result := 'number';
    tkEnumeration:
      Result := 'boolean'; // REST params of enum type are assumed boolean
  else
    Result := 'string'; // safe fallback
  end;
end;
```

- [ ] **Step 5: Verify tool names manually**

Add a temporary `begin...end` block in the `.dpr` (remove after) or trace through mentally:
- `PathToToolName('GET', '/customers')` → `'get_customers'`
- `PathToToolName('GET', '/customers/{id}')` → `'get_customers_by_id'`
- `PathToToolName('GET', '/customers/{customerId}')` → `'get_customers_by_customer_id'`
- `PathToToolName('DELETE', '/orders/{orderId}/items/{itemId}')` → `'delete_orders_by_order_id_items_by_item_id'`
- `PathToToolName('GET', '/customers/status')` → `'get_customers_status'` ← no conflict with `get_customers_by_status`

- [ ] **Step 6: Commit**

```bash
git add sources/MVCFramework.MCP.Bridge.pas
git commit -m "feat(bridge): implement tool name generation (CamelToSnake, PathToToolName)"
```

---

## Task 6: Implement TMCPEngineScanner

**Files:**
- Modify: `sources/MVCFramework.MCP.Bridge.pas`

- [ ] **Step 1: Implement ResolveMVCFromParamName helper**

```pascal
class function TMCPEngineScanner.ResolveMVCFromParamName(
  ARttiParam: TRttiParameter; const AAttrName: string): string;
begin
  // If the attribute carries an explicit name, use it; otherwise use the
  // Delphi parameter name from RTTI.
  if not AAttrName.IsEmpty then
    Result := AAttrName
  else
    Result := ARttiParam.Name;
end;
```

- [ ] **Step 2: Implement TMCPEngineScanner.Scan**

```pascal
class function TMCPEngineScanner.Scan(AEngine: TMVCEngine): TObjectList<TMCPBridgeRouteInfo>;
var
  LCtx: TRttiContext;
  LControllerInfo: TMVCControllerRoutingInfo;
  LRttiType: TRttiType;
  LMethod: TRttiMethod;
  LAttr, LParamAttr: TCustomAttribute;
  LPathAttr: MVCPathAttribute;
  LMethodAttr: MVCHTTPMethodAttribute;
  LDocAttr: MVCDocAttribute;
  LBasePath, LActionPath, LFullPath: string;
  LRoute: TMCPBridgeRouteInfo;
  LParam: TRttiParameter;
  LBridgeParam: TMCPBridgeParamInfo;
  LFromPath: MVCFromPathAttribute;
  LFromQuery: MVCFromQueryAttribute;
  LFromBody: MVCFromBodyAttribute;
  LToolName: string;
  LSeenNames: TDictionary<string, string>; // toolname → 'ControllerName.MethodName'
  LCollisionKey: string;
  LPrefixedName: string;
begin
  Result := TObjectList<TMCPBridgeRouteInfo>.Create(True);
  LSeenNames := TDictionary<string, string>.Create;
  LCtx := TRttiContext.Create;
  try
    for LControllerInfo in AEngine.Controllers do
    begin
      LRttiType := LCtx.GetType(LControllerInfo.Clazz);
      if LRttiType = nil then Continue;

      // Controller-level base path
      LBasePath := '';
      for LAttr in LRttiType.GetAttributes do
        if LAttr is MVCPathAttribute then
        begin
          LBasePath := MVCPathAttribute(LAttr).Value;
          Break;
        end;

      for LMethod in LRttiType.GetMethods do
      begin
        // Must have MVCHTTPMethod
        LMethodAttr := nil;
        LPathAttr := nil;
        LDocAttr := nil;

        for LAttr in LMethod.GetAttributes do
        begin
          if LAttr is MVCHTTPMethodAttribute then
            LMethodAttr := MVCHTTPMethodAttribute(LAttr)
          else if LAttr is MVCPathAttribute then
            LPathAttr := MVCPathAttribute(LAttr)
          else if LAttr is MVCDocAttribute then
            LDocAttr := MVCDocAttribute(LAttr);
        end;

        if LMethodAttr = nil then Continue;

        LActionPath := '';
        if LPathAttr <> nil then
          LActionPath := LPathAttr.Value;

        LFullPath := LBasePath + LActionPath;

        // Derive tool name from first HTTP method in the set
        // (a Delphi action rarely lists >1 method; use the first one)
        LToolName := PathToToolName(
          LMethodAttr.HTTPMethodAsString, LFullPath);

        // Collision detection
        LCollisionKey := LToolName;
        if LSeenNames.ContainsKey(LCollisionKey) then
        begin
          // Try prefix: snake-cased controller class name
          LPrefixedName := CamelToSnake(LRttiType.Name) + '_' + LToolName;
          if LSeenNames.ContainsKey(LPrefixedName) then
            raise EMCPBridgeException.CreateFmt(
              'MCPBridge: duplicate tool name "%s" cannot be resolved ' +
              'even with controller prefix. Conflicting actions: %s and %s.%s',
              [LToolName,
               LSeenNames[LCollisionKey],
               LRttiType.Name, LMethod.Name]);
          LToolName := LPrefixedName;
        end;

        LRoute := TMCPBridgeRouteInfo.Create;
        LRoute.ToolName := LToolName;
        LRoute.Description := IfThen(LDocAttr <> nil, LDocAttr.Value, '');
        LRoute.HTTPMethod := LMethodAttr.HTTPMethodAsString;
        LRoute.PathTemplate := LFullPath;
        LRoute.ControllerClassName := LRttiType.Name;

        // Scan parameters
        for LParam in LMethod.GetParameters do
        begin
          LFromPath  := nil;
          LFromQuery := nil;
          LFromBody  := nil;

          for LParamAttr in LParam.GetAttributes do
          begin
            if LParamAttr is MVCFromPathAttribute then
              LFromPath := MVCFromPathAttribute(LParamAttr)
            else if LParamAttr is MVCFromQueryAttribute then
              LFromQuery := MVCFromQueryAttribute(LParamAttr)
            else if LParamAttr is MVCFromBodyAttribute then
              LFromBody := MVCFromBodyAttribute(LParamAttr);
            // MVCFromHeader and MVCFromCookie are silently skipped
          end;

          if (LFromPath = nil) and (LFromQuery = nil) and (LFromBody = nil) then
            Continue; // no MVCFrom* → skip, TODO emitted by code gen

          LBridgeParam.TypeKind := LParam.ParamType.TypeKind;
          LBridgeParam.JsonSchemaType := DelphiTypeKindToJsonSchema(
            LParam.ParamType.TypeKind);

          if LFromPath <> nil then
          begin
            LBridgeParam.Name := ResolveMVCFromParamName(LParam, LFromPath.Name);
            LBridgeParam.Kind := bpkPath;
            LBridgeParam.Required := True;
            LBridgeParam.Description := 'Path parameter: ' + LBridgeParam.Name;
          end
          else if LFromQuery <> nil then
          begin
            LBridgeParam.Name := ResolveMVCFromParamName(LParam, LFromQuery.Name);
            LBridgeParam.Kind := bpkQuery;
            LBridgeParam.Required := LFromQuery.Required;
            LBridgeParam.Description := 'Query parameter: ' + LBridgeParam.Name;
          end
          else // LFromBody <> nil
          begin
            LBridgeParam.Name := 'body';
            LBridgeParam.Kind := bpkBody;
            LBridgeParam.Required := True;
            LBridgeParam.TypeKind := tkUString;
            LBridgeParam.JsonSchemaType := 'string';
            LBridgeParam.Description := 'Request body (JSON)';
          end;

          LRoute.Params := LRoute.Params + [LBridgeParam];
        end;

        Result.Add(LRoute);
        LSeenNames.Add(LToolName,
          LRttiType.Name + '.' + LMethod.Name);
      end;
    end;
  finally
    LSeenNames.Free;
    LCtx.Free;
  end;
end;
```

**Note for the implementer:** `LMethodAttr.HTTPMethodAsString` is a helper you may need to add or adapt depending on DMVCFramework's exact API for `TMVCHTTPMethodAttribute`. In DMVCFramework, `TMVCHTTPMethods` is a set of `TMVCHTTPMethodType`. Extract the first element: iterate the set or use a helper that returns `'GET'`, `'POST'`, etc. `MVCDocAttribute.Value` may be named differently — check `MVCFramework.Commons` for exact property names.

- [ ] **Step 3: Compile**

```
dcc32.exe sources/MVCFramework.MCP.Bridge.pas
```

- [ ] **Step 4: Commit**

```bash
git add sources/MVCFramework.MCP.Bridge.pas
git commit -m "feat(bridge): implement TMCPEngineScanner RTTI discovery"
```

---

## Task 7: Implement TMCPBridgeProvider (HTTP proxy)

**Files:**
- Modify: `sources/MVCFramework.MCP.Bridge.pas`

- [ ] **Step 1: Implement constructor/destructor**

```pascal
constructor TMCPBridgeProvider.Create(ARoutes: TObjectList<TMCPBridgeRouteInfo>;
  const ABaseURL: string);
begin
  inherited Create;
  FBaseURL := ABaseURL;
  FRoutes := ARoutes; // takes ownership
  FHTTPClient := TNetHTTPClient.Create(nil);
  FHTTPClient.ContentType := 'application/json';
  FHTTPClient.Accept := 'application/json';
end;

destructor TMCPBridgeProvider.Destroy;
begin
  FHTTPClient.Free;
  FRoutes.Free;
  inherited;
end;
```

- [ ] **Step 2: Implement FindRoute**

```pascal
function TMCPBridgeProvider.FindRoute(const AToolName: string): TMCPBridgeRouteInfo;
var
  LRoute: TMCPBridgeRouteInfo;
begin
  for LRoute in FRoutes do
    if SameText(LRoute.ToolName, AToolName) then
      Exit(LRoute);
  Result := nil;
end;
```

- [ ] **Step 3: Implement BuildURL**

```pascal
function TMCPBridgeProvider.BuildURL(ARoute: TMCPBridgeRouteInfo;
  AArguments: TJDOJsonObject): string;
var
  LPath: string;
  LParam: TMCPBridgeParamInfo;
  LValue: string;
begin
  LPath := ARoute.PathTemplate;
  for LParam in ARoute.Params do
  begin
    if LParam.Kind = bpkPath then
    begin
      LValue := '';
      if (AArguments <> nil) and AArguments.Contains(LParam.Name) then
        LValue := AArguments.S[LParam.Name];
      LPath := LPath.Replace('{' + LParam.Name + '}',
        TNetEncoding.URL.Encode(LValue));
    end;
  end;
  Result := FBaseURL + LPath;
end;
```

- [ ] **Step 4: Implement BuildQueryString**

```pascal
function TMCPBridgeProvider.BuildQueryString(ARoute: TMCPBridgeRouteInfo;
  AArguments: TJDOJsonObject): string;
var
  LParam: TMCPBridgeParamInfo;
  SB: TStringBuilder;
  LValue: string;
begin
  SB := TStringBuilder.Create;
  try
    for LParam in ARoute.Params do
    begin
      if LParam.Kind <> bpkQuery then Continue;
      if (AArguments = nil) or not AArguments.Contains(LParam.Name) then Continue;
      LValue := AArguments.S[LParam.Name];
      if SB.Length = 0 then SB.Append('?') else SB.Append('&');
      SB.Append(TNetEncoding.URL.Encode(LParam.Name));
      SB.Append('=');
      SB.Append(TNetEncoding.URL.Encode(LValue));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;
```

- [ ] **Step 5: Implement GetDynamicToolDefs**

```pascal
function TMCPBridgeProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;
var
  LRoute: TMCPBridgeRouteInfo;
  LDef: TMCPDynamicToolDef;
  LDefs: TArray<TMCPDynamicToolDef>;
  I: Integer;
begin
  SetLength(LDefs, FRoutes.Count);
  for I := 0 to FRoutes.Count - 1 do
  begin
    LRoute := FRoutes[I];
    LDef.Name := LRoute.ToolName;
    LDef.Description := LRoute.Description;
    LDef.ControllerClassName := LRoute.ControllerClassName;
    SetLength(LDef.Params, Length(LRoute.Params));
    for var J := 0 to High(LRoute.Params) do
    begin
      LDef.Params[J].Name          := LRoute.Params[J].Name;
      LDef.Params[J].Description   := LRoute.Params[J].Description;
      LDef.Params[J].Required      := LRoute.Params[J].Required;
      LDef.Params[J].TypeKind      := LRoute.Params[J].TypeKind;
      LDef.Params[J].JsonSchemaType := LRoute.Params[J].JsonSchemaType;
    end;
    LDefs[I] := LDef;
  end;
  Result := LDefs;
end;
```

- [ ] **Step 6: Implement InvokeDynamic**

```pascal
function TMCPBridgeProvider.InvokeDynamic(const AToolName: string;
  AArguments: TJDOJsonObject): TMCPToolResult;
var
  LRoute: TMCPBridgeRouteInfo;
  LURL: string;
  LResp: IHTTPResponse;
  LBodyParam: TMCPBridgeParamInfo;
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
  for LBodyParam in LRoute.Params do
    if LBodyParam.Kind = bpkBody then
    begin
      LHasBody := True;
      if (AArguments <> nil) and AArguments.Contains(LBodyParam.Name) then
        LBodyContent := AArguments.S[LBodyParam.Name];
      Break;
    end;

  try
    if LHasBody then
    begin
      LBodyStream := TStringStream.Create(LBodyContent, TEncoding.UTF8);
      try
        if SameText(LRoute.HTTPMethod, 'POST') then
          LResp := FHTTPClient.Post(LURL, LBodyStream)
        else if SameText(LRoute.HTTPMethod, 'PUT') then
          LResp := FHTTPClient.Put(LURL, LBodyStream)
        else if SameText(LRoute.HTTPMethod, 'PATCH') then
          LResp := FHTTPClient.Patch(LURL, LBodyStream)
        else
          LResp := FHTTPClient.Post(LURL, LBodyStream);
      finally
        LBodyStream.Free;
      end;
    end
    else
    begin
      if SameText(LRoute.HTTPMethod, 'GET') then
        LResp := FHTTPClient.Get(LURL)
      else if SameText(LRoute.HTTPMethod, 'DELETE') then
        LResp := FHTTPClient.Delete(LURL)
      else
        LResp := FHTTPClient.Get(LURL);
    end;

    if LResp.StatusCode < 400 then
      Result := TMCPToolResult.Text(LResp.ContentAsString)
    else
      Result := TMCPToolResult.Error(
        'HTTP ' + LResp.StatusCode.ToString + ': ' + LResp.ContentAsString);
  except
    on E: Exception do
      Result := TMCPToolResult.Error('Network error: ' + E.Message);
  end;
end;
```

- [ ] **Step 7: Compile**

```
dcc32.exe sources/MVCFramework.MCP.Bridge.pas
```

- [ ] **Step 8: Commit**

```bash
git add sources/MVCFramework.MCP.Bridge.pas
git commit -m "feat(bridge): implement TMCPBridgeProvider HTTP proxy"
```

---

## Task 8: Implement TMCPServerBridgeHelper

**Files:**
- Modify: `sources/MVCFramework.MCP.Bridge.pas`

- [ ] **Step 1: Implement RegisterFromEngine**

```pascal
procedure TMCPServerBridgeHelper.RegisterFromEngine(AEngine: TMVCEngine;
  const ABaseURL: string);
var
  LRoutes: TObjectList<TMCPBridgeRouteInfo>;
  LProvider: TMCPBridgeProvider;
begin
  if ABaseURL.IsEmpty then
    raise EMCPBridgeException.Create(
      'MCPBridge.RegisterFromEngine: ABaseURL must not be empty');

  LRoutes := TMCPEngineScanner.Scan(AEngine);
  // TMCPBridgeProvider takes ownership of LRoutes
  LProvider := TMCPBridgeProvider.Create(LRoutes, ABaseURL);
  // TMCPServer takes ownership of LProvider
  Self.RegisterDynamicProvider(LProvider);

  // Mark server info to signal prototype mode
  if not Self.ServerName.Contains('[bootstrap proxy') then
    Self.ServerName := Self.ServerName +
      ' [bootstrap proxy — not for production]';
end;
```

- [ ] **Step 2: Implement GenerateProviderUnit**

```pascal
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
```

- [ ] **Step 3: Compile**

```
dcc32.exe sources/MVCFramework.MCP.Bridge.pas
```

- [ ] **Step 4: Commit**

```bash
git add sources/MVCFramework.MCP.Bridge.pas
git commit -m "feat(bridge): implement TMCPServerBridgeHelper (RegisterFromEngine, GenerateProviderUnit)"
```

---

## Task 9: Implement TMCPBridgeCodeGen

**Files:**
- Modify: `sources/MVCFramework.MCP.Bridge.pas`

- [ ] **Step 1: Implement ToolNameToMethodName and ToolNameToProviderName helpers**

```pascal
class function TMCPBridgeCodeGen.ToolNameToMethodName(const AToolName: string): string;
var
  LParts: TArray<string>;
  SB: TStringBuilder;
  LPart: string;
begin
  // get_customers_by_id → GetCustomersById
  LParts := AToolName.Split(['_']);
  SB := TStringBuilder.Create;
  try
    for LPart in LParts do
      if not LPart.IsEmpty then
        SB.Append(UpperCase(LPart[1]) + LPart.Substring(1));
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TMCPBridgeCodeGen.ToolNameToProviderName(
  const AControllerClass: string): string;
var
  LName: string;
begin
  // TCustomersController → TCustomersMCPProvider
  LName := AControllerClass;
  if LName.StartsWith('T') then LName := LName.Substring(1);
  if LName.EndsWith('Controller') then
    LName := LName.Substring(0, Length(LName) - Length('Controller'));
  Result := 'T' + LName + 'MCPProvider';
end;
```

- [ ] **Step 2: Implement WriteProviderFile**

```pascal
procedure TMCPBridgeCodeGen.WriteProviderFile(const AOutputPath,
  AControllerClass: string; ARoutes: TObjectList<TMCPBridgeRouteInfo>);
var
  LFileName: string;
  LProviderName, LUnitName: string;
  SB: TStringBuilder;
  LRoute: TMCPBridgeRouteInfo;
  LParam: TMCPBridgeParamInfo;
  LFirst: Boolean;
  LDate: string;
begin
  LProviderName := ToolNameToProviderName(AControllerClass);
  // Remove leading T for unit name
  LUnitName := 'MCP' + AControllerClass;
  if LUnitName.EndsWith('Controller') then
    LUnitName := LUnitName.Substring(0, Length(LUnitName) - Length('Controller'));
  LUnitName := LUnitName + 'ProviderU';

  LFileName := IncludeTrailingPathDelimiter(AOutputPath) + LUnitName + '.pas';
  LDate := FormatDateTime('yyyy-mm-dd', Now);

  SB := TStringBuilder.Create;
  try
    SB.AppendLine('// *** GENERATED ' + LDate +
      ' — REVIEW AND CURATE BEFORE PRODUCTION USE ***');
    SB.AppendLine('// Source: ' + AControllerClass);
    SB.AppendLine('// Generator: MVCFramework.MCP.Bridge / GenerateProviderUnit');
    SB.AppendLine('');
    SB.AppendLine('unit ' + LUnitName + ';');
    SB.AppendLine('');
    SB.AppendLine('interface');
    SB.AppendLine('');
    SB.AppendLine('uses');
    SB.AppendLine('  MVCFramework.MCP.ToolProvider, MVCFramework.MCP.Attributes,');
    SB.AppendLine('  MVCFramework.MCP.Server, System.Net.HttpClient,');
    SB.AppendLine('  System.Net.URLClient, System.Classes, System.SysUtils;');
    SB.AppendLine('');
    SB.AppendLine('type');
    SB.AppendLine('  ' + LProviderName + ' = class(TMCPToolProvider)');
    SB.AppendLine('  private');
    SB.AppendLine('    FBaseURL: string;');
    SB.AppendLine('  public');
    SB.AppendLine('    constructor Create; override;');
    SB.AppendLine('');

    // Method declarations
    for LRoute in ARoutes do
    begin
      if LRoute.Description.IsEmpty then
        SB.AppendLine('    // TODO: add description (no [MVCDoc] found on action)');
      SB.AppendLine('    [MCPTool(''' + LRoute.ToolName + ''', ''' +
        StringReplace(LRoute.Description, '''', '''''', [rfReplaceAll]) + ''')]');
      SB.Append('    function ' + ToolNameToMethodName(LRoute.ToolName) + '(');
      LFirst := True;
      for LParam in LRoute.Params do
      begin
        if not LFirst then SB.Append(';');
        SB.AppendLine('');
        SB.Append('      [MCPParam(''' + LParam.Description + '''');
        if not LParam.Required then SB.Append(', False');
        SB.Append(')] const ' + LParam.Name + ': ');
        case LParam.TypeKind of
          tkInteger: SB.Append('Integer');
          tkInt64:   SB.Append('Int64');
          tkFloat:   SB.Append('Double');
          tkEnumeration: SB.Append('Boolean');
        else
          SB.Append('string');
        end;
        LFirst := False;
      end;
      SB.AppendLine('');
      SB.AppendLine('    ): TMCPToolResult;');
      SB.AppendLine('');
    end;

    SB.AppendLine('  end;');
    SB.AppendLine('');
    SB.AppendLine('implementation');
    SB.AppendLine('');

    // Constructor
    SB.AppendLine('constructor ' + LProviderName + '.Create;');
    SB.AppendLine('begin');
    SB.AppendLine('  inherited;');
    SB.AppendLine('  FBaseURL := ''http://localhost:8080'';' +
      ' // TODO: move to config / .env');
    SB.AppendLine('end;');
    SB.AppendLine('');

    // Method implementations
    for LRoute in ARoutes do
    begin
      SB.AppendLine('function ' + LProviderName + '.' +
        ToolNameToMethodName(LRoute.ToolName) + '(');
      LFirst := True;
      for LParam in LRoute.Params do
      begin
        if not LFirst then SB.AppendLine(';');
        SB.Append('  const ' + LParam.Name + ': ');
        case LParam.TypeKind of
          tkInteger: SB.Append('Integer');
          tkInt64:   SB.Append('Int64');
          tkFloat:   SB.Append('Double');
          tkEnumeration: SB.Append('Boolean');
        else SB.Append('string');
        end;
        LFirst := False;
      end;
      SB.AppendLine('');
      SB.AppendLine('): TMCPToolResult;');
      SB.AppendLine('var');
      SB.AppendLine('  LClient: TNetHTTPClient;');
      SB.AppendLine('  LResp: IHTTPResponse;');
      if LRoute.PathTemplate.Contains('{') then
        SB.AppendLine('  LURL: string;');

      // Determine if has body param
      var LHasBody := False;
      var LBodyParamName := '';
      for LParam in LRoute.Params do
        if LParam.Kind = bpkBody then
        begin
          LHasBody := True;
          LBodyParamName := LParam.Name;
          Break;
        end;
      if LHasBody then
        SB.AppendLine('  LBodyStream: TStringStream;');

      SB.AppendLine('begin');
      SB.AppendLine('  LClient := TNetHTTPClient.Create(nil);');
      if LHasBody then
        SB.AppendLine('  LBodyStream := TStringStream.Create(' +
          LBodyParamName + ', TEncoding.UTF8);');
      SB.AppendLine('  try');

      // Build URL inline
      var LURLExpr := 'FBaseURL + ''' + LRoute.PathTemplate + '''';
      for LParam in LRoute.Params do
        if LParam.Kind = bpkPath then
          LURLExpr := 'FBaseURL + ''' +
            LRoute.PathTemplate.Replace('{' + LParam.Name + '}', '''+' +
            LParam.Name + '+''') + '''';
      // Query params
      var LQueryParts: TArray<string>;
      for LParam in LRoute.Params do
        if LParam.Kind = bpkQuery then
          LQueryParts := LQueryParts + [
            '''' + LParam.Name + '='' + ' + LParam.Name + '.ToString'];
      if Length(LQueryParts) > 0 then
        LURLExpr := LURLExpr + ' + ''?' + String.Join('&', LQueryParts) + '''';

      // HTTP call
      if LHasBody then
      begin
        if SameText(LRoute.HTTPMethod, 'PUT') then
          SB.AppendLine('    LResp := LClient.Put(' + LURLExpr + ', LBodyStream);')
        else
          SB.AppendLine('    LResp := LClient.Post(' + LURLExpr + ', LBodyStream);');
      end
      else
      begin
        if SameText(LRoute.HTTPMethod, 'DELETE') then
          SB.AppendLine('    LResp := LClient.Delete(' + LURLExpr + ');')
        else
          SB.AppendLine('    LResp := LClient.Get(' + LURLExpr + ');');
      end;

      SB.AppendLine('    if LResp.StatusCode < 400 then');
      SB.AppendLine('      Result := TMCPToolResult.Text(LResp.ContentAsString)');
      SB.AppendLine('    else');
      SB.AppendLine('      Result := TMCPToolResult.Error(');
      SB.AppendLine('        ''HTTP '' + LResp.StatusCode.ToString + '': '' + LResp.ContentAsString);');
      SB.AppendLine('  finally');
      if LHasBody then
        SB.AppendLine('    LBodyStream.Free;');
      SB.AppendLine('    LClient.Free;');
      SB.AppendLine('  end;');
      SB.AppendLine('end;');
      SB.AppendLine('');
    end;

    SB.AppendLine('initialization');
    SB.AppendLine('  TMCPServer.Instance.RegisterToolProvider(' + LProviderName + ');');
    SB.AppendLine('');
    SB.AppendLine('end.');

    TFile.WriteAllText(LFileName, SB.ToString, TEncoding.UTF8);
    LogI('MCPBridge: generated ' + LFileName);
  finally
    SB.Free;
  end;
end;
```

- [ ] **Step 3: Implement GenerateAll**

```pascal
constructor TMCPBridgeCodeGen.Create(AServer: TMCPServer);
begin
  inherited Create;
  FServer := AServer;
end;

procedure TMCPBridgeCodeGen.GenerateAll(const AOutputPath: string);
var
  LByController: TDictionary<string, TObjectList<TMCPBridgeRouteInfo>>;
  LDynProvider: TMCPToolProvider;
  LBridgeProvider: TMCPBridgeProvider;
  LRoute: TMCPBridgeRouteInfo;
  LGroup: TObjectList<TMCPBridgeRouteInfo>;
  LPair: TPair<string, TObjectList<TMCPBridgeRouteInfo>>;
begin
  LByController := TDictionary<string, TObjectList<TMCPBridgeRouteInfo>>.Create;
  try
    // Collect routes from all dynamic providers in the server
    for LDynProvider in FServer.DynamicProviders do
    begin
      if not (LDynProvider is TMCPBridgeProvider) then Continue;
      LBridgeProvider := TMCPBridgeProvider(LDynProvider);
      for LRoute in LBridgeProvider.Routes do
      begin
        if not LByController.TryGetValue(LRoute.ControllerClassName, LGroup) then
        begin
          LGroup := TObjectList<TMCPBridgeRouteInfo>.Create(False);
          LByController.Add(LRoute.ControllerClassName, LGroup);
        end;
        LGroup.Add(LRoute);
      end;
    end;

    for LPair in LByController do
      WriteProviderFile(AOutputPath, LPair.Key, LPair.Value);
  finally
    for LPair in LByController do
      LPair.Value.Free;
    LByController.Free;
  end;
end;
```

**Note:** `FServer.DynamicProviders` requires adding a `DynamicProviders` read-only property to `TMCPServer` (returns `FDynamicProviders`). Add it in Task 2 if not already done, or add it now:

In `TMCPServer` public section:
```pascal
property DynamicProviders: TObjectList<TMCPToolProvider> read FDynamicProviders;
```

Also add a `Routes` read-only property to `TMCPBridgeProvider`:
```pascal
property Routes: TObjectList<TMCPBridgeRouteInfo> read FRoutes;
```

- [ ] **Step 4: Compile the full Bridge unit**

```
dcc32.exe sources/MVCFramework.MCP.Bridge.pas
```

Expected: full clean compile.

- [ ] **Step 5: Compile test project**

```
dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin
```

- [ ] **Step 6: Commit**

```bash
git add sources/MVCFramework.MCP.Bridge.pas sources/MVCFramework.MCP.Server.pas
git commit -m "feat(bridge): implement TMCPBridgeCodeGen Pascal code emitter"
```

---

## Task 10: Add test REST controller and wire bridge in test project

**Files:**
- Create: `tests/testproject/MCPBridgeTestControllerU.pas`
- Modify: `tests/testproject/EngineConfigU.pas`

- [ ] **Step 1: Create MCPBridgeTestControllerU.pas**

```pascal
unit MCPBridgeTestControllerU;

interface

uses
  MVCFramework, MVCFramework.Commons;

type
  [MVCPath('/bridge-test')]
  [MVCDoc('Bridge integration test controller')]
  TMCPBridgeTestController = class(TMVCController)
  public
    [MVCPath('')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Returns a fixed greeting')]
    procedure GetGreeting;

    [MVCPath('/{name}')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Returns a greeting for the given name')]
    procedure GetGreetingByName(
      [MVCFromPath] const name: string
    );

    [MVCPath('/search')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Searches items by keyword')]
    procedure SearchItems(
      [MVCFromQuery('q')] const q: string;
      [MVCFromQuery('limit', False)] const limit: Integer
    );

    [MVCPath('/echo')]
    [MVCHTTPMethod([httpPOST])]
    [MVCDoc('Echoes the request body')]
    procedure PostEcho(
      [MVCFromBody] const body: string
    );
  end;

implementation

uses
  System.SysUtils, MVCFramework.Logger;

procedure TMCPBridgeTestController.GetGreeting;
begin
  Render('{"message":"hello from bridge-test"}');
end;

procedure TMCPBridgeTestController.GetGreetingByName(const name: string);
begin
  Render('{"message":"hello ' + name + '"}');
end;

procedure TMCPBridgeTestController.SearchItems(const q: string; const limit: Integer);
var
  LLimit: Integer;
begin
  LLimit := limit;
  if LLimit <= 0 then LLimit := 10;
  Render('{"q":"' + q + '","limit":' + LLimit.ToString + ',"results":[]}');
end;

procedure TMCPBridgeTestController.PostEcho(const body: string);
begin
  Render(body);
end;

end.
```

- [ ] **Step 2: Wire bridge in EngineConfigU.pas**

```pascal
procedure ConfigureEngine(AEngine: TMVCEngine);
begin
  AEngine.AddController(TMCPSessionController);
  AEngine.AddController(TMCPBridgeTestController);  // ← add

  AEngine.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');

  // Bootstrap bridge — exposes /bridge-test/* as MCP tools.
  // Remove after GenerateProviderUnit() has been called and output curated.
  TMCPServer.Instance.RegisterFromEngine(AEngine, 'http://localhost:8080');
end;
```

Add to the uses clause of `EngineConfigU.pas`:
```pascal
  MVCFramework.MCP.Bridge,
  MCPBridgeTestControllerU,
```

- [ ] **Step 3: Compile test server**

```
dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin
```

Expected: clean compile.

- [ ] **Step 4: Start test server and verify tools/list includes bridge tools**

Start: `tests/testproject/bin/MCPServerUnitTest.exe`

In a separate terminal:
```
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}"
```

Then `tools/list` — verify tools like `get_bridge_test`, `get_bridge_test_by_name`, `get_bridge_test_search`, `post_bridge_test_echo` appear in the list.

- [ ] **Step 5: Commit**

```bash
git add tests/testproject/MCPBridgeTestControllerU.pas tests/testproject/EngineConfigU.pas
git commit -m "test(bridge): add TMCPBridgeTestController and wire RegisterFromEngine in test project"
```

---

## Task 11: Add bridge test cases to MCPClientTest and run integration tests

**Files:**
- Modify: `tests/clientproject/MCPClientTest.dpr`

- [ ] **Step 1: Add TestBridge procedure**

Add before the `var` block at the bottom:

```pascal
procedure TestBridge(AClient: TMCPClientBase; AR: TTestRunner);
var
  LTools: TJSONArray;
  LTool: TJSONObject;
  I: Integer;
  LBridgeToolCount: Integer;
  LResult: string;
begin
  AR.Section('Bridge Proxy Tools');

  // Verify bridge tools appear in tools/list
  LTools := nil;
  try
    LTools := AClient.ListTools;
    LBridgeToolCount := 0;
    for I := 0 to LTools.Count - 1 do
    begin
      if LTools.Items[I] is TJSONObject then
      begin
        LTool := TJSONObject(LTools.Items[I]);
        if Assigned(LTool.FindValue('name')) and
           (LTool.GetValue<string>('name', '').StartsWith('get_bridge_test') or
            LTool.GetValue<string>('name', '').StartsWith('post_bridge_test')) then
          Inc(LBridgeToolCount);
      end;
    end;
    if LBridgeToolCount >= 4 then
      AR.Ok(Format('bridge tools present in tools/list (%d found)', [LBridgeToolCount]))
    else
      AR.Fail('bridge tools/list',
        Format('expected 4+ bridge tools, found %d', [LBridgeToolCount]));
  except
    on E: Exception do
      AR.Fail('bridge tools/list', E.ClassName + ': ' + E.Message);
  end;
  LTools.Free;

  // Call get_bridge_test (no params)
  try
    LResult := AClient.CallTool('get_bridge_test', nil);
    if Pos('hello', LResult) > 0 then
      AR.Ok('get_bridge_test → contains "hello"')
    else
      AR.Fail('get_bridge_test', 'expected "hello" in result, got: ' + Copy(LResult, 1, 100));
  except
    on E: Exception do
      AR.Fail('get_bridge_test', E.ClassName + ': ' + E.Message);
  end;

  // Call get_bridge_test_by_name with name param
  try
    LResult := AClient.CallTool('get_bridge_test_by_name',
      TJSONObject.Create.AddPair('name', 'World'));
    if Pos('World', LResult) > 0 then
      AR.Ok('get_bridge_test_by_name("World") → contains "World"')
    else
      AR.Fail('get_bridge_test_by_name', 'expected "World" in result, got: ' + Copy(LResult, 1, 100));
  except
    on E: Exception do
      AR.Fail('get_bridge_test_by_name', E.ClassName + ': ' + E.Message);
  end;

  // Call get_bridge_test_search with query params
  try
    LResult := AClient.CallTool('get_bridge_test_search',
      TJSONObject.Create.AddPair('q', 'hello'));
    if Pos('"q":"hello"', LResult) > 0 then
      AR.Ok('get_bridge_test_search(q="hello") → q echoed in result')
    else
      AR.Fail('get_bridge_test_search', 'expected q in result, got: ' + Copy(LResult, 1, 100));
  except
    on E: Exception do
      AR.Fail('get_bridge_test_search', E.ClassName + ': ' + E.Message);
  end;

  // Call post_bridge_test_echo with body
  try
    LResult := AClient.CallTool('post_bridge_test_echo',
      TJSONObject.Create.AddPair('body', '{"ping":true}'));
    if Pos('ping', LResult) > 0 then
      AR.Ok('post_bridge_test_echo(body) → body echoed')
    else
      AR.Fail('post_bridge_test_echo', 'expected "ping" in result, got: ' + Copy(LResult, 1, 100));
  except
    on E: Exception do
      AR.Fail('post_bridge_test_echo', E.ClassName + ': ' + E.Message);
  end;
end;
```

- [ ] **Step 2: Call TestBridge in the main block**

In the main `begin...end`, after `TestPrompts(LClient, LR)`, add:

```pascal
        TestBridge(LClient, LR);
```

- [ ] **Step 3: Compile client**

```
dcc32.exe tests/clientproject/MCPClientTest.dpr -Etests/clientproject/bin
```

- [ ] **Step 4: Run full integration test suite**

Start the test server. Then:

```
tests/clientproject/bin/MCPClientTest.exe
```

Expected output contains:
```
--- Bridge Proxy Tools ---
  [PASS] bridge tools present in tools/list (4 found)
  [PASS] get_bridge_test → contains "hello"
  [PASS] get_bridge_test_by_name("World") → contains "World"
  [PASS] get_bridge_test_search(q="hello") → q echoed in result
  [PASS] post_bridge_test_echo(body) → body echoed
```

All existing tests must still pass (no regressions).

- [ ] **Step 5: Smoke test GenerateProviderUnit**

Add temporarily to the test server `.dpr` (before `Boot`), run once, then remove:

```pascal
TMCPServer.Instance.RegisterFromEngine(AEngine, 'http://localhost:8080');
TMCPServer.Instance.GenerateProviderUnit('output/');
```

Verify `output/MCPBridgeTestProviderU.pas` exists and contains `[MCPTool('get_bridge_test'`, `[MCPTool('get_bridge_test_by_name'`, etc. Compile the generated file to verify syntactic correctness.

- [ ] **Step 6: Commit**

```bash
git add tests/clientproject/MCPClientTest.dpr
git commit -m "test(bridge): add TestBridge integration test cases to MCPClientTest"
```

---

## Task 12: Final compile verification + cleanup

- [ ] **Step 1: Clean build of all projects**

```
dcc32.exe sources/MVCFramework.MCP.Bridge.pas
dcc32.exe tests/testproject/MCPServerUnitTest.dpr -Etests/testproject/bin
dcc32.exe tests/clientproject/MCPClientTest.dpr  -Etests/clientproject/bin
```

All must compile without warnings or errors.

- [ ] **Step 2: Full integration test run**

Start test server. Run client. Verify 100% pass.

- [ ] **Step 3: Final commit**

```bash
git add -u
git commit -m "feat(bridge): MCPBridge complete — RegisterFromEngine + GenerateProviderUnit"
```
