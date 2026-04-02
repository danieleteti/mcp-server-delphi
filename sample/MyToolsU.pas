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

unit MyToolsU;

interface

uses
  MVCFramework.MCP.ToolProvider,
  MVCFramework.MCP.Attributes;

type
  TMyTools = class(TMCPToolProvider)
  public
    [MCPTool('reverse_string', 'Reverses a string')]
    function ReverseString(
      [MCPParam('The string to reverse')] const value: string
    ): TMCPToolResult;

    [MCPTool('string_length', 'Returns the length of a string')]
    function StringLength(
      [MCPParam('The string to measure')] const value: string
    ): TMCPToolResult;

    [MCPTool('echo', 'Echoes back the input message')]
    function Echo(
      [MCPParam('The message to echo')] const message: string
    ): TMCPToolResult;
  end;

implementation

uses
  System.SysUtils, System.StrUtils, MVCFramework.MCP.Server;

{ TMyTools }

function TMyTools.ReverseString(const value: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(System.StrUtils.ReverseString(value));
end;

function TMyTools.StringLength(const value: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(IntToStr(Length(value)));
end;

function TMyTools.Echo(const message: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(message);
end;

initialization
  TMCPServer.Instance.RegisterToolProvider(TMyTools);

end.
