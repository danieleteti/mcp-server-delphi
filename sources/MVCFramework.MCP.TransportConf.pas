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

implementation

uses
  System.SysUtils, MVCFramework.Logger;

var
  GIsStdio: Boolean;

function MCPTransportIsStdio: Boolean;
begin
  Result := GIsStdio;
end;

function DetectStdioTransport: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    if SameText(ParamStr(I), '--transport') and (I < ParamCount) and
       SameText(ParamStr(I + 1), 'stdio') then
      Exit(True);
    if SameText(ParamStr(I), '--transport=stdio') then
      Exit(True);
  end;
end;

initialization
  GIsStdio := DetectStdioTransport;
  if GIsStdio then
    UseConsoleLogger := False;

end.
