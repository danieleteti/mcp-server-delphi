// ***************************************************************************
//
// MCP Server for DMVCFramework - Quick Start
//
// Copyright (c) 2010-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// QUICK START  HTTP + STDIO (Indy Direct backend)
// =================================================
// Ready-to-run MCP server with both HTTP and stdio transports.
// Customize the provider units in the ../shared/ folder  they are
// shared with the stdio-only Quick Start project.
//
// The HTTP transport runs on DMVCFramework's Indy Direct server
// (TMVCEngine.Create + TMVCServerFactory.CreateIndyDirect).
// No WebBroker, no TWebModule, no TIdHTTPWebBrokerBridge: the engine
// dispatches requests straight from TIdHTTPServer.
//
// If you only need stdio transport, use the quickstart_stdio project
// instead  it has zero HTTP dependencies.
//
// HOW TO USE:
//   1. Open this project in Delphi (or compile from command line)
//   2. Make sure DMVCFramework and the "sources" folder are in your search path
//   3. Build and run
//   4. Connect any MCP-compatible AI client to http://localhost:8080/mcp
//
// TRANSPORTS:
//   QuickStart.exe                     --> HTTP on port 8080 (default)
//   QuickStart.exe --transport http    --> HTTP on port 8080
//   QuickStart.exe --transport stdio   --> stdio (for Claude Desktop local mode)
//
// ***************************************************************************

program QuickStart;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MVCFramework,
  MVCFramework.Logger,
  MVCFramework.DotEnv,
  MVCFramework.Commons,
  MVCFramework.Server.Intf,
  MVCFramework.Server.Factory,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Stdio,
  MVCFramework.Signal,
  // IMPORTANT: TransportConf MUST be listed BEFORE provider units.
  // It detects --transport stdio early and disables the console logger,
  // preventing log output on stdout (MCP stdio requires clean stdout).
  MVCFramework.MCP.TransportConf,
  // --- Your MCP providers (shared with quickstart_stdio project) ---
  // Each unit auto-registers its providers in the "initialization" section,
  // so just adding them to this uses clause is enough to activate them.
  // Customize these files in the ../shared/ folder.
  ToolProviderU in '..\shared\ToolProviderU.pas',
  ResourceProviderU in '..\shared\ResourceProviderU.pas',
  PromptProviderU in '..\shared\PromptProviderU.pas';

// {$R *.res}  // Uncomment after generating the .res file in Delphi IDE


// ---------------------------------------------------------------------------
// BuildEngine: configures TMVCEngine for IndyDirect
//
// TMVCEngine.Create is the speaking constructor for the
// Indy Direct backend. No TWebModule is created; the engine owns the
// request pipeline outright.
// ---------------------------------------------------------------------------
function BuildEngine: TMVCEngine;
begin
  Result := TMVCEngine.Create(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.APPLICATION_JSON;
      Config[TMVCConfigKey.DefaultContentCharset] := TMVCConstants.DEFAULT_CONTENT_CHARSET;
      Config[TMVCConfigKey.ExposeServerSignature] := 'false';
    end);

  // MCP session termination (HTTP DELETE on /mcp) per spec 2025-03-26.
  Result.AddController(TMCPSessionController);

  // Publish the MCP endpoint at "/mcp". The factory creates a fresh
  // TMCPEndpoint per request; registered tools / resources / prompts
  // are discovered automatically via RTTI.
  Result.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');
end;

// ---------------------------------------------------------------------------
// RunHTTPServer: starts the HTTP transport (Streamable HTTP)
// The MCP endpoint will be available at http://localhost:<port>/mcp
// ---------------------------------------------------------------------------
procedure RunHTTPServer(APort: Integer);
var
  LEngine: TMVCEngine;
  LServer: IMVCServer;
begin
  LEngine := BuildEngine;
  try
    LServer := TMVCServerFactory.CreateIndyDirect(LEngine);
    LServer.Listen(APort);

    LogI('MCP Server listening on http://localhost:' + APort.ToString + '/mcp');
    LogI('Press Ctrl+C to shut down.');

    // Block until Ctrl+C or SIGTERM
    WaitForTerminationSignal;
    EnterInShutdownState;
    LServer.Stop;
    LServer := nil;
  finally
    LEngine.Free;
  end;
end;

// ---------------------------------------------------------------------------
// RunStdio: starts the stdio transport
// Reads JSON-RPC from stdin, writes responses to stdout.
// Used when an AI client (e.g. Claude Desktop) launches the server directly.
// ---------------------------------------------------------------------------
procedure RunStdio;
var
  LTransport: TMCPStdioTransport;
begin
  LTransport := TMCPStdioTransport.Create(TMCPServer.Instance);
  try
    LTransport.Run;  // Blocks until stdin closes (EOF)
  finally
    LTransport.Free;
  end;
end;

// ---------------------------------------------------------------------------
// ParseTransport: reads --transport <http|stdio> from the command line
// ---------------------------------------------------------------------------
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
    if ParamStr(I).StartsWith('--transport=', True) then
    begin
      Result := LowerCase(Copy(ParamStr(I), Length('--transport=') + 1, MaxInt));
      Exit;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
var
  LTransport: string;
begin
  IsMultiThread := True;

  // --- Parse transport BEFORE any logging ---
  // In stdio mode we must disable the console logger to keep stdout clean.
  LTransport := ParseTransport;
  if LTransport = 'stdio' then
    UseConsoleLogger := False
  else
    UseConsoleLogger := True;
  UseLoggerVerbosityLevel := TLogLevel.levNormal;

  // --- Configure MCP server identity ---
  // These values are returned to AI clients during the "initialize" handshake.
  // Change them to match your application.
  TMCPServer.Instance.ServerName := 'MyMCPServer';
  TMCPServer.Instance.ServerVersion := '1.0.0';

  // --- Launch the selected transport ---
  if LTransport = 'stdio' then
  begin
    try
      RunStdio;
    except
      on E: Exception do
        // In stdio mode, errors go to stderr (never stdout)
        System.Write(ErrOutput, E.ClassName + ': ' + E.Message + sLineBreak);
    end;
  end
  else if LTransport = 'http' then
  begin
    LogI('** MCP Quick Start Server ** powered by DMVCFramework');
    try
      // Port is read from .env file, or defaults to 8080
      RunHTTPServer(dotEnv.Env('dmvc.server.port', 8080));
    except
      on E: Exception do
        LogF(E.ClassName + ': ' + E.Message);
    end;
  end
  else
  begin
    WriteLn(ErrOutput, 'Unknown transport: ' + LTransport);
    WriteLn(ErrOutput, 'Usage: QuickStart [--transport http|stdio]');
    ExitCode := 1;
  end;
end.
