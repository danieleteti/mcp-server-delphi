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
// ***************************************************************************

unit MVCFramework.MCP.StdioOnly;

{ Include this unit (BEFORE any provider unit) in the uses clause of a
  stdio-only MCP server. Its initialization section unconditionally
  disables the default console logger, so provider-registration LogI
  calls never leak on stdout.

  MCP stdio transport reserves stdout for JSON-RPC messages: any extra
  bytes break the client. Use this unit for servers that are ALWAYS
  stdio (no HTTP fallback, no --transport flag). For dual-transport
  servers use MVCFramework.MCP.TransportConf instead - that one leaves
  the console logger on for HTTP mode. }

interface

implementation

uses
  MVCFramework.Logger;

initialization
  UseConsoleLogger := False;

end.
