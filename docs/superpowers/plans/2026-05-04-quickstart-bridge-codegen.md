# Quickstart Bridge & CodeGen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two quickstart projects — `quickstart_bridge` (auto-exposes a DMVCFramework REST server as MCP via `RegisterFromEngine`) and `quickstart_codegen` (CLI that generates a static Pascal provider unit from the same REST API).

**Architecture:** `BooksControllerU.pas` (a demo REST controller) lives in `quickstart_bridge/` and is reused by `quickstart_codegen/` via a relative path reference. Both projects use the existing `sources/` library. `quickstart_bridge` is an HTTP-only server that runs the REST API and the MCP endpoint on the same port. `quickstart_codegen` is a one-shot CLI that creates the engine, calls `RegisterFromEngine`, runs `GenerateProviderUnit`, and exits — no HTTP listener is started.

**Tech Stack:** Delphi 11+, DMVCFramework (`MVCFramework.pas`, `MVCFramework.MCP.Bridge`), `sources/` MCP library, Indy Direct backend.

---

## File Map

| File | Status | Role |
|------|--------|------|
| `quickstart/quickstart_bridge/BooksControllerU.pas` | **Create** | Demo REST controller — 4 endpoints, shared by codegen |
| `quickstart/quickstart_bridge/EngineConfigU.pas` | **Create** | Engine wiring: AddController → RegisterFromEngine → TMCPSessionController → PublishObject |
| `quickstart/quickstart_bridge/QuickStartBridge.dpr` | **Create** | HTTP-only MCP+REST server entry point |
| `quickstart/quickstart_bridge/QuickStartBridge.dproj` | **Create** | Delphi IDE project file |
| `quickstart/quickstart_codegen/QuickStartCodeGen.dpr` | **Create** | One-shot codegen CLI |
| `quickstart/quickstart_codegen/QuickStartCodeGen.dproj` | **Create** | Delphi IDE project file |
| `quickstart/quickstart_codegen/generated/.gitkeep` | **Create** | Placeholder for generated output (git tracks the directory) |

---

## Background: key patterns

### RegisterFromEngine ordering

`RegisterFromEngine` scans ALL controllers registered with the engine at call time. `TMCPSessionController` (the MCP HTTP DELETE /mcp handler) must be added **after** the call so it is not exposed as a bridge tool. The correct order in `EngineConfigU` is:

```
1. AddController(TBooksController)          ← scanned  ✓
2. RegisterFromEngine(LEngine, baseURL)     ← scans here
3. AddController(TMCPSessionController)     ← not scanned ✓
4. PublishObject(... '/mcp')
```

### Generated unit naming

For class `TBooksController`, `GenerateProviderUnit` produces:
- **Unit name:** `MCPTBooksProviderU`
- **File name:** `MCPTBooksProviderU.pas`
- **Provider class:** `TBooksMCPProvider`

### Tool names produced by the scanner

The bridge tool names follow `<http_method>_<path_segments>`:

| Controller action | HTTP | Path | MCP tool name |
|---|---|---|---|
| `GetBooks` | GET | `/api/books` | `get_api_books` |
| `GetBookById` | GET | `/api/books/($id)` | `get_api_books_by_id` |
| `SearchBooks` | GET | `/api/books/search` | `get_api_books_search` |
| `CreateBook` | POST | `/api/books` | `post_api_books` |

---

## Task 1 — BooksControllerU.pas

**Files:**
- Create: `quickstart/quickstart_bridge/BooksControllerU.pas`

- [ ] **Step 1: Create the file**

```pascal
// ***************************************************************************
//
// MCP Bridge Quickstart — Demo REST controller
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// BOOKS CONTROLLER
// ================
// A minimal REST API used to demonstrate the MCPBridge feature.
// In a real project this would be replaced by your own controllers.
//
// Endpoints:
//   GET  /api/books              → list all books (hard-coded demo data)
//   GET  /api/books/($id)        → get one book by id
//   GET  /api/books/search?q=... → search by keyword (returns empty results)
//   POST /api/books              → echo-create (returns the body as received)
//
// ***************************************************************************
unit BooksControllerU;

interface

uses
  MVCFramework,
  MVCFramework.Commons;

type
  [MVCPath('/api/books')]
  TBooksController = class(TMVCController)
  public
    [MVCPath]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Returns the list of all books')]
    procedure GetBooks;

    [MVCPath('/($id)')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Returns the book with the given id')]
    procedure GetBookById(const id: string);

    [MVCPath('/search')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Searches books by title keyword. Use limit to cap the result count (default 10)')]
    procedure SearchBooks(
      const [MVCFromQueryString('q')] q: string;
      const [MVCFromQueryString('limit', '10')] limit: Integer
    );

    [MVCPath]
    [MVCHTTPMethod([httpPOST])]
    [MVCDoc('Creates a new book. Send a JSON body with title and author fields')]
    procedure CreateBook(const [MVCFromBody] body: string);
  end;

implementation

uses
  System.SysUtils;

const
  BOOKS_JSON =
    '[' +
    '{"id":"1","title":"The Pragmatic Programmer","author":"Hunt & Thomas"},' +
    '{"id":"2","title":"Clean Code","author":"Robert C. Martin"},' +
    '{"id":"3","title":"Design Patterns","author":"Gang of Four"}' +
    ']';

procedure TBooksController.GetBooks;
begin
  Render(BOOKS_JSON);
end;

procedure TBooksController.GetBookById(const id: string);
begin
  case id of
    '1': Render('{"id":"1","title":"The Pragmatic Programmer","author":"Hunt & Thomas"}');
    '2': Render('{"id":"2","title":"Clean Code","author":"Robert C. Martin"}');
    '3': Render('{"id":"3","title":"Design Patterns","author":"Gang of Four"}');
  else
    ResponseStatus(404);
    Render('{"error":"Book not found","id":"' + id + '"}');
  end;
end;

procedure TBooksController.SearchBooks(const q: string; const limit: Integer);
begin
  Render(Format('{"q":"%s","limit":%d,"results":[]}', [q, limit]));
end;

procedure TBooksController.CreateBook(const body: string);
begin
  Render('{"created":true,"body":' + body + '}');
end;

end.
```

- [ ] **Step 2: Commit**

```
git add quickstart/quickstart_bridge/BooksControllerU.pas
git commit -m "feat(quickstart_bridge): add BooksControllerU demo REST controller"
```

---

## Task 2 — EngineConfigU.pas

**Files:**
- Create: `quickstart/quickstart_bridge/EngineConfigU.pas`

- [ ] **Step 1: Create the file**

```pascal
// ***************************************************************************
//
// MCP Bridge Quickstart — Engine configuration
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
unit EngineConfigU;

interface

uses
  MVCFramework;

procedure ConfigureEngine(AEngine: TMVCEngine);

implementation

uses
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Bridge,
  BooksControllerU;

procedure ConfigureEngine(AEngine: TMVCEngine);
begin
  // ── Step 1: register business controllers ─────────────────────────────
  AEngine.AddController(TBooksController);

  // ── Step 2: scan the engine and create MCP bridge tools ───────────────
  // RegisterFromEngine is called HERE, after the business controllers are
  // added but before TMCPSessionController, so that the session controller
  // is not exposed as a bridge tool (it would create a delete_mcp tool that
  // terminates the session, which is not what we want).
  TMCPServer.Instance.RegisterFromEngine(AEngine, 'http://localhost:8080');

  // ── Step 3: MCP infrastructure (added AFTER the scan) ─────────────────
  AEngine.AddController(TMCPSessionController);

  // ── Step 4: publish the MCP endpoint at /mcp ──────────────────────────
  AEngine.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');
end;

end.
```

- [ ] **Step 2: Commit**

```
git add quickstart/quickstart_bridge/EngineConfigU.pas
git commit -m "feat(quickstart_bridge): add EngineConfigU with RegisterFromEngine wiring"
```

---

## Task 3 — QuickStartBridge.dpr

**Files:**
- Create: `quickstart/quickstart_bridge/QuickStartBridge.dpr`

- [ ] **Step 1: Create the file**

```pascal
// ***************************************************************************
//
// MCP Bridge Quickstart
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// QUICKSTART — MCPBridge (HTTP)
// ==============================
// An existing DMVCFramework REST server that also exposes an MCP endpoint.
// RegisterFromEngine() (called inside EngineConfigU) scans the registered
// controllers at startup and creates one MCP proxy tool per REST action.
//
// The REST API and the MCP endpoint share the same port (8080 by default):
//
//   REST API  → http://localhost:8080/api/books
//   MCP server → http://localhost:8080/mcp
//
// HOW TO USE:
//   1. Build and run this project
//   2. Point any MCP client at http://localhost:8080/mcp
//   3. The AI can call get_api_books, get_api_books_by_id,
//      get_api_books_search, post_api_books as MCP tools
//
// ADAPTING TO YOUR OWN PROJECT:
//   1. Replace BooksControllerU with your own controller(s)
//   2. Change 'http://localhost:8080' in EngineConfigU to your server URL
//      when running the REST server and MCP server as separate processes
//   3. Remove the "[bootstrap proxy — not for production]" warning by NOT
//      calling RegisterFromEngine and instead using the generated static
//      provider from the quickstart_codegen project
//
// ***************************************************************************

program QuickStartBridge;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MVCFramework,
  MVCFramework.Logger,
  MVCFramework.Commons,
  MVCFramework.Server.Intf,
  MVCFramework.Server.Factory,
  MVCFramework.Signal,
  MVCFramework.MCP.Server,
  EngineConfigU in 'EngineConfigU.pas',
  BooksControllerU in 'BooksControllerU.pas';

const
  PORT = 8080;

var
  LEngine: TMVCEngine;
  LServer: IMVCServer;
begin
  ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;
  MVCSerializeNulls := True;
  MVCNameCaseDefault := TMVCNameCase.ncCamelCase;
  UseConsoleLogger := True;
  UseLoggerVerbosityLevel := TLogLevel.levNormal;

  TMCPServer.Instance.ServerName := 'QuickStartBridge';
  TMCPServer.Instance.ServerVersion := '1.0.0';

  LogI('** QuickStart Bridge — REST + MCP server **');

  LEngine := TMVCEngine.Create(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType]    := TMVCMediaType.APPLICATION_JSON;
      Config[TMVCConfigKey.DefaultContentCharset] := TMVCConstants.DEFAULT_CONTENT_CHARSET;
      Config[TMVCConfigKey.ExposeServerSignature] := 'false';
    end);
  try
    ConfigureEngine(LEngine);
    LServer := TMVCServerFactory.CreateIndyDirect(LEngine);
    LServer.Listen(PORT);

    LogI('REST API  : http://localhost:' + PORT.ToString + '/api/books');
    LogI('MCP server: http://localhost:' + PORT.ToString + '/mcp');
    LogI('Press Ctrl+C to shut down.');

    WaitForTerminationSignal;
    EnterInShutdownState;
    LServer.Stop;
    LServer := nil;
  finally
    LEngine.Free;
  end;
end.
```

- [ ] **Step 2: Commit**

```
git add quickstart/quickstart_bridge/QuickStartBridge.dpr
git commit -m "feat(quickstart_bridge): add QuickStartBridge.dpr HTTP server entry point"
```

---

## Task 4 — QuickStartBridge.dproj

**Files:**
- Create: `quickstart/quickstart_bridge/QuickStartBridge.dproj`

- [ ] **Step 1: Create the file**

```xml
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
    <PropertyGroup>
        <ProjectGuid>{D4E5F6A7-B8C9-0123-DEFA-456789012345}</ProjectGuid>
        <MainSource>QuickStartBridge.dpr</MainSource>
        <Base>True</Base>
        <Config Condition="'$(Config)'==''">Debug</Config>
        <ProjectName Condition="'$(ProjectName)'==''">QuickStartBridge</ProjectName>
        <TargetedPlatforms>1</TargetedPlatforms>
        <AppType>Console</AppType>
        <FrameworkType>None</FrameworkType>
        <ProjectVersion>20.3</ProjectVersion>
        <Platform Condition="'$(Platform)'==''">Win32</Platform>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Config)'=='Base' or '$(Base)'!=''">
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="('$(Platform)'=='Win32' and '$(Base)'=='true') or '$(Base_Win32)'!=''">
        <Base_Win32>true</Base_Win32>
        <CfgParent>Base</CfgParent>
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Config)'=='Release' or '$(Cfg_1)'!=''">
        <Cfg_1>true</Cfg_1>
        <CfgParent>Base</CfgParent>
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Config)'=='Debug' or '$(Cfg_2)'!=''">
        <Cfg_2>true</Cfg_2>
        <CfgParent>Base</CfgParent>
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="('$(Platform)'=='Win32' and '$(Cfg_2)'=='true') or '$(Cfg_2_Win32)'!=''">
        <Cfg_2_Win32>true</Cfg_2_Win32>
        <CfgParent>Cfg_2</CfgParent>
        <Cfg_2>true</Cfg_2>
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Base)'!=''">
        <DCC_E>false</DCC_E>
        <DCC_F>false</DCC_F>
        <DCC_K>false</DCC_K>
        <DCC_N>false</DCC_N>
        <DCC_S>false</DCC_S>
        <DCC_ImageBase>00400000</DCC_ImageBase>
        <SanitizedProjectName>QuickStartBridge</SanitizedProjectName>
        <VerInfo_Keys>CompanyName=;FileDescription=;FileVersion=1.0.0.0;InternalName=;LegalCopyright=;LegalTrademarks=;OriginalFilename=;ProductName=;ProductVersion=1.0.0.0;Comments=</VerInfo_Keys>
        <DCC_Namespace>System;Xml;Data;Datasnap;Web;Soap;$(DCC_Namespace)</DCC_Namespace>
        <Icon_MainIcon>$(BDS)\bin\delphi_PROJECTICON.ico</Icon_MainIcon>
        <Icns_MainIcns>$(BDS)\bin\delphi_PROJECTICNS.icns</Icns_MainIcns>
        <DCC_ExeOutput>.\bin</DCC_ExeOutput>
        <DCC_UnitSearchPath>..\..\sources;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Cfg_2)'!=''">
        <DCC_Define>DEBUG;$(DCC_Define)</DCC_Define>
        <DCC_DebugDCUs>true</DCC_DebugDCUs>
        <DCC_Optimize>false</DCC_Optimize>
        <DCC_GenerateStackFrames>true</DCC_GenerateStackFrames>
        <DCC_DebugInfoInExe>true</DCC_DebugInfoInExe>
        <DCC_RemoteDebug>true</DCC_RemoteDebug>
        <DCC_RangeChecking>true</DCC_RangeChecking>
        <DCC_IntegerOverflowCheck>true</DCC_IntegerOverflowCheck>
    </PropertyGroup>
    <PropertyGroup Condition="('$(Platform)'=='Win32' and '$(Cfg_2)'=='true') or '$(Cfg_2_Win32)'!=''">
        <VerInfo_Locale>1033</VerInfo_Locale>
        <Manifest_File>(None)</Manifest_File>
        <AppDPIAwarenessMode>none</AppDPIAwarenessMode>
    </PropertyGroup>
    <ItemGroup>
        <DelphiCompile Include="$(MainSource)">
            <MainSource>MainSource</MainSource>
        </DelphiCompile>
        <DCCReference Include="BooksControllerU.pas"/>
        <DCCReference Include="EngineConfigU.pas"/>
        <BuildConfiguration Include="Base">
            <Key>Base</Key>
        </BuildConfiguration>
        <BuildConfiguration Include="Release">
            <Key>Cfg_1</Key>
            <CfgParent>Base</CfgParent>
        </BuildConfiguration>
        <BuildConfiguration Include="Debug">
            <Key>Cfg_2</Key>
            <CfgParent>Base</CfgParent>
        </BuildConfiguration>
    </ItemGroup>
    <ProjectExtensions>
        <Borland.Personality>Delphi.Personality.12</Borland.Personality>
        <Borland.ProjectType/>
        <BorlandProject>
            <Delphi.Personality>
                <Source>
                    <Source Name="MainSource">QuickStartBridge.dpr</Source>
                </Source>
            </Delphi.Personality>
            <Platforms>
                <Platform value="Win32">True</Platform>
                <Platform value="Win64">False</Platform>
            </Platforms>
        </BorlandProject>
    </ProjectExtensions>
    <Import Project="$(BDS)\Bin\CodeGear.Delphi.Targets" Condition="Exists('$(BDS)\Bin\CodeGear.Delphi.Targets')"/>
    <Import Project="$(APPDATA)\Embarcadero\$(BDSAPPDATABASEDIR)\$(PRODUCTVERSION)\UserTools.proj" Condition="Exists('$(APPDATA)\Embarcadero\$(BDSAPPDATABASEDIR)\$(PRODUCTVERSION)\UserTools.proj')"/>
    <Import Project="$(MSBuildProjectName).deployproj" Condition="Exists('$(MSBuildProjectName).deployproj')"/>
</Project>
```

- [ ] **Step 2: Compile**

```
MSBuild quickstart\quickstart_bridge\QuickStartBridge.dproj /t:Build /p:Config=Debug /p:Platform=Win32 /nologo
```

Expected output (last 5 lines):
```
  Embarcadero Delphi for Win32 compiler version 37.0
  Copyright (c) 1983,2026 Embarcadero Technologies, Inc.
  <N> lines, <T> seconds, ...
Compilation complete.
    Warnings: 0    Errors: 0
```

- [ ] **Step 3: Commit**

```
git add quickstart/quickstart_bridge/QuickStartBridge.dproj
git commit -m "feat(quickstart_bridge): add dproj — bridge quickstart compiles clean"
```

---

## Task 5 — QuickStartCodeGen.dpr

**Files:**
- Create: `quickstart/quickstart_codegen/QuickStartCodeGen.dpr`
- Create: `quickstart/quickstart_codegen/generated/.gitkeep`

- [ ] **Step 1: Create the .gitkeep placeholder**

Create an empty file at `quickstart/quickstart_codegen/generated/.gitkeep`.

- [ ] **Step 2: Create QuickStartCodeGen.dpr**

```pascal
// ***************************************************************************
//
// MCP Bridge Quickstart — Code Generator
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// QUICKSTART — MCPBridge Code Generator
// ======================================
// A one-shot CLI tool that scans a DMVCFramework engine and generates a
// static Pascal provider unit that can be used instead of the runtime bridge.
//
// Usage:
//   QuickStartCodeGen.exe                     → writes to .\generated\
//   QuickStartCodeGen.exe C:\path\to\output   → writes to the given directory
//
// What it does:
//   1. Creates a TMVCEngine and registers TBooksController
//   2. Calls RegisterFromEngine to create the bridge tools in memory
//   3. Calls GenerateProviderUnit to write the Pascal source
//   4. Prints the generated file names and exits
//
// The generated unit (MCPTBooksProviderU.pas) contains a TBooksMCPProvider
// class — a static TMCPToolProvider subclass with one method per REST action.
// It can be registered with:
//   TMCPServer.Instance.RegisterToolProvider(TBooksMCPProvider)
//
// ADAPTING TO YOUR OWN PROJECT:
//   Replace BooksControllerU / TBooksController below with your own
//   controller, then run the tool to regenerate the provider.
//
// ***************************************************************************

program QuickStartCodeGen;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Bridge,
  BooksControllerU in '..\quickstart_bridge\BooksControllerU.pas';

// The base URL the generated provider will use for proxy calls.
// Change this to your REST server address if it lives on a different host.
const
  BASE_URL = 'http://localhost:8080';

var
  LEngine: TMVCEngine;
  LOutputPath: string;
  LFiles: TArray<string>;
  LFile: string;
begin
  ReportMemoryLeaksOnShutdown := True;

  WriteLn('MCPBridge Code Generator');
  WriteLn('========================');
  WriteLn;

  // Resolve output path: first CLI argument or default to .\generated
  if ParamCount >= 1 then
    LOutputPath := ParamStr(1)
  else
    LOutputPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'generated');

  WriteLn('Output path : ', LOutputPath);
  WriteLn('Base URL    : ', BASE_URL);
  WriteLn;

  if not ForceDirectories(LOutputPath) and not DirectoryExists(LOutputPath) then
  begin
    WriteLn('ERROR: Cannot create output directory: ', LOutputPath);
    ExitCode := 1;
    Exit;
  end;

  TMCPServer.Instance.ServerName := 'QuickStartBridge';

  // Build a minimal engine — only business controllers, no session controller,
  // no published objects. We never call Listen(); this is for scanning only.
  LEngine := TMVCEngine.Create(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.APPLICATION_JSON;
    end);
  try
    LEngine.AddController(TBooksController);
    TMCPServer.Instance.RegisterFromEngine(LEngine, BASE_URL);
    TMCPServer.Instance.GenerateProviderUnit(LOutputPath);
  finally
    LEngine.Free;
  end;

  LFiles := TDirectory.GetFiles(LOutputPath, '*.pas');
  if Length(LFiles) = 0 then
    WriteLn('No .pas files found in output directory — nothing was generated.')
  else
  begin
    for LFile in LFiles do
      WriteLn('[GEN] ', TPath.GetFileName(LFile));
    WriteLn;
    WriteLn('Done. Review the generated file(s) and add them to your MCP server project.');
    WriteLn;
    WriteLn('Next steps:');
    WriteLn('  1. Open the generated .pas in your editor');
    WriteLn('  2. Add it to your MCP project''s uses / DCCReference');
    WriteLn('  3. The initialization section auto-registers the provider — ');
    WriteLn('     nothing else is needed.');
  end;
end.
```

- [ ] **Step 3: Commit**

```
git add quickstart/quickstart_codegen/QuickStartCodeGen.dpr
git add quickstart/quickstart_codegen/generated/.gitkeep
git commit -m "feat(quickstart_codegen): add QuickStartCodeGen CLI and generated/ placeholder"
```

---

## Task 6 — QuickStartCodeGen.dproj

**Files:**
- Create: `quickstart/quickstart_codegen/QuickStartCodeGen.dproj`

- [ ] **Step 1: Create the file**

```xml
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
    <PropertyGroup>
        <ProjectGuid>{E5F6A7B8-C9D0-1234-EFAB-567890123456}</ProjectGuid>
        <MainSource>QuickStartCodeGen.dpr</MainSource>
        <Base>True</Base>
        <Config Condition="'$(Config)'==''">Debug</Config>
        <ProjectName Condition="'$(ProjectName)'==''">QuickStartCodeGen</ProjectName>
        <TargetedPlatforms>1</TargetedPlatforms>
        <AppType>Console</AppType>
        <FrameworkType>None</FrameworkType>
        <ProjectVersion>20.3</ProjectVersion>
        <Platform Condition="'$(Platform)'==''">Win32</Platform>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Config)'=='Base' or '$(Base)'!=''">
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="('$(Platform)'=='Win32' and '$(Base)'=='true') or '$(Base_Win32)'!=''">
        <Base_Win32>true</Base_Win32>
        <CfgParent>Base</CfgParent>
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Config)'=='Release' or '$(Cfg_1)'!=''">
        <Cfg_1>true</Cfg_1>
        <CfgParent>Base</CfgParent>
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Config)'=='Debug' or '$(Cfg_2)'!=''">
        <Cfg_2>true</Cfg_2>
        <CfgParent>Base</CfgParent>
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="('$(Platform)'=='Win32' and '$(Cfg_2)'=='true') or '$(Cfg_2_Win32)'!=''">
        <Cfg_2_Win32>true</Cfg_2_Win32>
        <CfgParent>Cfg_2</CfgParent>
        <Cfg_2>true</Cfg_2>
        <Base>true</Base>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Base)'!=''">
        <DCC_E>false</DCC_E>
        <DCC_F>false</DCC_F>
        <DCC_K>false</DCC_K>
        <DCC_N>false</DCC_N>
        <DCC_S>false</DCC_S>
        <DCC_ImageBase>00400000</DCC_ImageBase>
        <SanitizedProjectName>QuickStartCodeGen</SanitizedProjectName>
        <VerInfo_Keys>CompanyName=;FileDescription=;FileVersion=1.0.0.0;InternalName=;LegalCopyright=;LegalTrademarks=;OriginalFilename=;ProductName=;ProductVersion=1.0.0.0;Comments=</VerInfo_Keys>
        <DCC_Namespace>System;Xml;Data;Datasnap;Web;Soap;$(DCC_Namespace)</DCC_Namespace>
        <Icon_MainIcon>$(BDS)\bin\delphi_PROJECTICON.ico</Icon_MainIcon>
        <Icns_MainIcns>$(BDS)\bin\delphi_PROJECTICNS.icns</Icns_MainIcns>
        <DCC_ExeOutput>.\bin</DCC_ExeOutput>
        <DCC_UnitSearchPath>..\..\sources;..\quickstart_bridge;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>
    </PropertyGroup>
    <PropertyGroup Condition="'$(Cfg_2)'!=''">
        <DCC_Define>DEBUG;$(DCC_Define)</DCC_Define>
        <DCC_DebugDCUs>true</DCC_DebugDCUs>
        <DCC_Optimize>false</DCC_Optimize>
        <DCC_GenerateStackFrames>true</DCC_GenerateStackFrames>
        <DCC_DebugInfoInExe>true</DCC_DebugInfoInExe>
        <DCC_RemoteDebug>true</DCC_RemoteDebug>
        <DCC_RangeChecking>true</DCC_RangeChecking>
        <DCC_IntegerOverflowCheck>true</DCC_IntegerOverflowCheck>
    </PropertyGroup>
    <PropertyGroup Condition="('$(Platform)'=='Win32' and '$(Cfg_2)'=='true') or '$(Cfg_2_Win32)'!=''">
        <VerInfo_Locale>1033</VerInfo_Locale>
        <Manifest_File>(None)</Manifest_File>
        <AppDPIAwarenessMode>none</AppDPIAwarenessMode>
    </PropertyGroup>
    <ItemGroup>
        <DelphiCompile Include="$(MainSource)">
            <MainSource>MainSource</MainSource>
        </DelphiCompile>
        <DCCReference Include="..\quickstart_bridge\BooksControllerU.pas"/>
        <BuildConfiguration Include="Base">
            <Key>Base</Key>
        </BuildConfiguration>
        <BuildConfiguration Include="Release">
            <Key>Cfg_1</Key>
            <CfgParent>Base</CfgParent>
        </BuildConfiguration>
        <BuildConfiguration Include="Debug">
            <Key>Cfg_2</Key>
            <CfgParent>Base</CfgParent>
        </BuildConfiguration>
    </ItemGroup>
    <ProjectExtensions>
        <Borland.Personality>Delphi.Personality.12</Borland.Personality>
        <Borland.ProjectType/>
        <BorlandProject>
            <Delphi.Personality>
                <Source>
                    <Source Name="MainSource">QuickStartCodeGen.dpr</Source>
                </Source>
            </Delphi.Personality>
            <Platforms>
                <Platform value="Win32">True</Platform>
                <Platform value="Win64">False</Platform>
            </Platforms>
        </BorlandProject>
    </ProjectExtensions>
    <Import Project="$(BDS)\Bin\CodeGear.Delphi.Targets" Condition="Exists('$(BDS)\Bin\CodeGear.Delphi.Targets')"/>
    <Import Project="$(APPDATA)\Embarcadero\$(BDSAPPDATABASEDIR)\$(PRODUCTVERSION)\UserTools.proj" Condition="Exists('$(APPDATA)\Embarcadero\$(BDSAPPDATABASEDIR)\$(PRODUCTVERSION)\UserTools.proj')"/>
    <Import Project="$(MSBuildProjectName).deployproj" Condition="Exists('$(MSBuildProjectName).deployproj')"/>
</Project>
```

- [ ] **Step 2: Compile**

```
MSBuild quickstart\quickstart_codegen\QuickStartCodeGen.dproj /t:Build /p:Config=Debug /p:Platform=Win32 /nologo
```

Expected output (last lines):
```
    Warnings: 0    Errors: 0
```

- [ ] **Step 3: Run the codegen and verify output**

```
quickstart\quickstart_codegen\bin\QuickStartCodeGen.exe
```

Expected console output:
```
MCPBridge Code Generator
========================

Output path : ...\quickstart_codegen\bin\generated
Base URL    : http://localhost:8080

[GEN] MCPTBooksProviderU.pas

Done. Review the generated file(s) and add them to your MCP server project.
...
```

Verify `quickstart_codegen/bin/generated/MCPTBooksProviderU.pas` exists and contains `TBooksMCPProvider`.

- [ ] **Step 4: Commit**

```
git add quickstart/quickstart_codegen/QuickStartCodeGen.dproj
git commit -m "feat(quickstart_codegen): add dproj — codegen compiles and generates TBooksMCPProvider"
```

---

## Task 7 — Smoke test quickstart_bridge

**Files:** No changes — runtime test only.

- [ ] **Step 1: Start the bridge server**

```
quickstart\quickstart_bridge\bin\QuickStartBridge.exe
```

Expected log output:
```
[INFO] ** QuickStart Bridge — REST + MCP server **
[INFO] REST API  : http://localhost:8080/api/books
[INFO] MCP server: http://localhost:8080/mcp
[INFO] Press Ctrl+C to shut down.
```

- [ ] **Step 2: Verify REST API**

In a second terminal:
```
curl http://localhost:8080/api/books
```
Expected: `[{"id":"1","title":"The Pragmatic Programmer",...},...]`

- [ ] **Step 3: Verify MCP tools list**

```
curl -X POST http://localhost:8080/mcp ^
  -H "Content-Type: application/json" ^
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}"
```

Note the `Mcp-Session-Id` header in the response. Then:

```
curl -X POST http://localhost:8080/mcp ^
  -H "Content-Type: application/json" ^
  -H "Mcp-Session-Id: <id-from-above>" ^
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
```

Expected: JSON with `tools` array containing `get_api_books`, `get_api_books_by_id`, `get_api_books_search`, `post_api_books`.

- [ ] **Step 4: Stop the server (Ctrl+C)**

- [ ] **Step 5: Commit final**

```
git add .
git commit -m "feat(quickstart): add quickstart_bridge and quickstart_codegen examples"
```

---

## Self-Review

### Spec coverage
- [x] `quickstart_bridge` — REST server bridged to MCP via `RegisterFromEngine` ✓
- [x] `quickstart_codegen` — generates static Pascal provider unit ✓  
- [x] Shared `BooksControllerU.pas` reused by both ✓
- [x] `TMCPSessionController` added after `RegisterFromEngine` to avoid `delete_mcp` tool ✓
- [x] Generated unit: `MCPTBooksProviderU.pas` / class `TBooksMCPProvider` ✓
- [x] Both projects have `.dproj` with correct `DCC_UnitSearchPath` ✓
- [x] Codegen writes to `./generated` by default, accepts override via CLI arg ✓

### Placeholder scan
No TBD/TODO/placeholder text found.

### Type consistency
- `TBooksController` defined in Task 1, referenced in Tasks 2, 5, 6 ✓
- `ConfigureEngine` defined in Task 2, called in Task 3 ✓
- `TMCPServer.Instance.RegisterFromEngine` / `GenerateProviderUnit` — public methods on `TMCPServerBridgeHelper`, available when `MVCFramework.MCP.Bridge` is in uses ✓
