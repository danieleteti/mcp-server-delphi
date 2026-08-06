// ***************************************************************************
//
// MCP Bridge Quickstart - Code Generator
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// QUICKSTART - MCPBridge Code Generator
// ======================================
// A one-shot CLI tool that scans a DMVCFramework engine and generates a
// static Pascal provider unit that can be used instead of the runtime bridge.
//
// Usage:
//   QuickStartCodeGen.exe                     -> writes to .\generated\
//   QuickStartCodeGen.exe C:\path\to\output   -> writes to the given directory
//
// What it does:
//   1. Creates a TMVCEngine and registers TBooksController
//   2. Calls RegisterFromEngine to create the bridge tools in memory
//   3. Calls GenerateProviderUnit to write the Pascal source
//   4. Prints the generated file names and exits
//
// The generated unit (MCPTBooksProviderU.pas) contains a TBooksMCPProvider
// class - a static TMCPToolProvider subclass with one method per REST action.
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

  // Build a minimal engine - only business controllers, no session controller,
  // no published objects. We never call Listen(); this is for scanning only.
  LEngine := TMVCEngine.Create(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.APPLICATION_JSON;
      // Without this DMVCFramework's own /system/* controller is registered too
      // and the scanner would generate a provider for it as well.
      Config[TMVCConfigKey.LoadSystemControllers] := 'false';
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
    WriteLn('No .pas files found in output directory - nothing was generated.')
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
    WriteLn('  3. The initialization section auto-registers the provider - ');
    WriteLn('     nothing else is needed.');
  end;
end.
