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

unit MVCFramework.MCP.TransportConf;

{ Early transport detection.
  This unit MUST be listed BEFORE any provider units in the .dpr uses clause.
  It checks the command line for --transport stdio and disables the console
  logger to prevent log output on stdout (MCP stdio spec requires stdout
  to contain only valid MCP messages). }

interface

function MCPTransportIsStdio: Boolean;

{ For a program whose default transport is stdio (a local MCP server that
  clients launch as a child process): call it as the first statement of the
  .dpr. From then on the program is in stdio mode unless the command line
  says "--transport http". Started with no --transport at all, it says so on
  stderr, because a console that waits on stdin looks like a hung program. }
procedure MCPDefaultTransportStdio;

implementation

uses
  System.SysUtils, MVCFramework.Logger;

var
  GIsStdio: Boolean;

function MCPTransportIsStdio: Boolean;
begin
  Result := GIsStdio;
end;

// '' when the command line has no --transport
function TransportArgument: string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ParamCount do
  begin
    if SameText(ParamStr(I), '--transport') and (I < ParamCount) then
      Exit(LowerCase(ParamStr(I + 1)));
    if ParamStr(I).StartsWith('--transport=', True) then
      Exit(LowerCase(Copy(ParamStr(I), Length('--transport=') + 1, MaxInt)));
  end;
end;

function DetectStdioTransport: Boolean;
begin
  Result := TransportArgument = 'stdio';
end;

procedure MCPDefaultTransportStdio;
begin
  GIsStdio := TransportArgument <> 'http';
  if GIsStdio then
  begin
    UseConsoleLogger := False;
    if TransportArgument = '' then
      System.Write(ErrOutput, 'No --transport given: MCP over stdin/stdout (stdio). ' +
        'Start with "--transport http" for the HTTP server.' + sLineBreak);
  end;
end;

initialization
  GIsStdio := DetectStdioTransport;
  if GIsStdio then
    UseConsoleLogger := False;

end.
