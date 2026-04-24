// ***************************************************************************
//
// MCP Server for DMVCFramework - Quick Start (stdio only)
//
// Copyright (c) 2010-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// QUICK START — STDIO ONLY
// ========================
// This is a lightweight MCP server that uses only the stdio transport.
// It does NOT require TaurusTLS, Indy, or any HTTP stack.
//
// The AI client (e.g. Claude Desktop) launches this executable and
// communicates via stdin/stdout using JSON-RPC 2.0 messages.
//
// This project shares the provider units with the quickstart (HTTP+stdio)
// project — customize them in the ../shared/ folder.
//
// HOW TO USE:
//   1. Open this project in Delphi (or compile from command line)
//   2. Make sure DMVCFramework and the "sources" folder are in your search path
//   3. Build
//   4. Configure your AI client to launch this executable (see below)
//
// CLAUDE DESKTOP CONFIGURATION:
//   Add to %APPDATA%\Claude\claude_desktop_config.json:
//   {
//     "mcpServers": {
//       "my-server": {
//         "command": "C:\\path\\to\\QuickStartStdio.exe"
//       }
//     }
//   }
//
// CLAUDE CODE CONFIGURATION:
//   claude mcp add my-server C:\path\to\QuickStartStdio.exe
//
// ***************************************************************************

program QuickStartStdio;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Stdio,
  // IMPORTANT: StdioOnly MUST be listed BEFORE the provider units.
  // Its initialization section disables the default console logger so
  // provider-registration LogI calls never leak on stdout (MCP stdio
  // reserves stdout for JSON-RPC messages).
  MVCFramework.MCP.StdioOnly,
  // --- Your MCP providers (shared with quickstart HTTP+stdio project) ---
  // Customize these files in the ../shared/ folder.
  ToolProviderU in '..\shared\ToolProviderU.pas',
  ResourceProviderU in '..\shared\ResourceProviderU.pas',
  PromptProviderU in '..\shared\PromptProviderU.pas';

// {$R *.res}  // Uncomment after generating the .res file in Delphi IDE

var
  LTransport: TMCPStdioTransport;
begin
  // --- Configure MCP server identity ---
  // These values are returned to AI clients during the "initialize" handshake.
  // Change them to match your application.
  TMCPServer.Instance.ServerName := 'MyMCPServer';
  TMCPServer.Instance.ServerVersion := '1.0.0';

  // --- Run the stdio transport ---
  // Reads JSON-RPC requests from stdin, writes responses to stdout.
  // Blocks until stdin is closed (EOF) by the AI client.
  LTransport := TMCPStdioTransport.Create(TMCPServer.Instance);
  try
    try
      LTransport.Run;
    except
      on E: Exception do
        // In stdio mode, errors MUST go to stderr (never stdout).
        // stdout is reserved exclusively for MCP JSON-RPC messages.
        System.Write(ErrOutput, E.ClassName + ': ' + E.Message + sLineBreak);
    end;
  finally
    LTransport.Free;
  end;
end.
