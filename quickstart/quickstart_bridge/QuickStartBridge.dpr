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
// QUICKSTART - MCPBridge (HTTP)
// ==============================
// An existing DMVCFramework REST server that also exposes an MCP endpoint.
// RegisterFromEngine() (called inside EngineConfigU) scans the registered
// controllers at startup and creates one MCP proxy tool per REST action.
//
// The REST API and the MCP endpoint share the same port (8080 by default):
//
//   REST API   -> http://localhost:8080/api/books
//   MCP server -> http://localhost:8080/mcp
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
//   3. Remove the "[bootstrap proxy - not for production]" warning by NOT
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
  UseConsoleLogger := True;
  UseLoggerVerbosityLevel := TLogLevel.levNormal;

  TMCPServer.Instance.ServerName := 'QuickStartBridge';
  TMCPServer.Instance.ServerVersion := '1.0.0';

  LogI('** QuickStart Bridge - REST + MCP server **');

  LEngine := TMVCEngine.Create(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType]    := TMVCMediaType.APPLICATION_JSON;
      Config[TMVCConfigKey.DefaultContentCharset] := TMVCConstants.DEFAULT_CONTENT_CHARSET;
      Config[TMVCConfigKey.ExposeServerSignature] := 'false';
      // Without this DMVCFramework's own /system/* controller is registered too
      // and RegisterFromEngine would expose it as MCP tools.
      Config[TMVCConfigKey.LoadSystemControllers] := 'false';
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
