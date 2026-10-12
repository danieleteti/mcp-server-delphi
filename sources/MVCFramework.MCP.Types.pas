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

unit MVCFramework.MCP.Types;

interface

uses
  JsonDataObjects;

const
  MCP_SERVER_LIBRARY_VERSION = '0.9.0';
  MCP_PROTOCOL_VERSION = '2025-03-26';
  MCP_ENDPOINT = '/mcp';
  { Set in TWebContext.Data by MCPGuard on every request it let through. The
    value says whether the guard authenticated the request itself (token, or
    nothing to authenticate) or left authentication to the application
    (AuthenticationHandledElsewhere): in that case the endpoint also requires
    a valid logged user. }
  MCP_GUARD_MARK = 'mcp.guard';
  MCP_GUARD_VETTED = '1';
  MCP_GUARD_VETTED_AUTH_ELSEWHERE = 'auth-elsewhere';
  MCP_SESSION_HEADER = 'Mcp-Session-Id';
  MCP_ERR_SESSION = -32001;

// Tool-name rules imposed by OpenAI-compatible function calling.
//
// The MCP specification puts no constraint on a tool name, but every provider
// that maps MCP tools onto function calling does: OpenAI, Anthropic, Azure and
// Bedrock all reject a request whose tool names do not match
// ^[a-zA-Z0-9_-]{1,128}$, and they reject the whole request, not the offending
// tool. A server whose names carry a dot or a space therefore works against a
// hand-written client and fails against every real model, which is a painful
// way to find out. MCPIsValidToolName answers the question; MCPSanitizeToolName
// coerces a generated name into the accepted alphabet.
function MCPIsValidToolName(const AName: string): Boolean;

// Maps every character outside [A-Za-z0-9_-] to '_' and truncates to the
// 128-character limit. Intended for names the framework derives from
// something else (a route path, a class name), never to silently rewrite a
// name the developer wrote by hand.
function MCPSanitizeToolName(const AName: string): string;

type
  {$SCOPEDENUMS ON}
  TMCPTransportKind = (Http, Stdio);
  {$SCOPEDENUMS OFF}

  { Who is calling, as far as the transport knows. Empty user on stdio and on
    an unauthenticated HTTP endpoint. }
  TMCPCaller = record
    Transport: TMCPTransportKind;
    UserName: string;
    Roles: TArray<string>;
  end;

  TMCPCapabilities = record
    SupportsTools: Boolean;
    SupportsResources: Boolean;
    SupportsPrompts: Boolean;
    function ToJSON: TJDOJsonObject;
  end;

  TMCPServerInfo = record
    Name: string;
    Version: string;
    function ToJSON: TJDOJsonObject;
  end;

  TMCPClientInfo = record
    Name: string;
    Version: string;
    procedure FromJSON(const AJSON: TJDOJsonObject);
  end;

implementation

uses
  System.SysUtils;

const
  MCP_TOOL_NAME_MAX_LEN = 128;

function IsToolNameChar(const AChar: Char): Boolean;
begin
  Result := CharInSet(AChar, ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-']);
end;

function MCPIsValidToolName(const AName: string): Boolean;
var
  I: Integer;
begin
  if (AName = '') or (Length(AName) > MCP_TOOL_NAME_MAX_LEN) then
    Exit(False);
  for I := 1 to Length(AName) do
    if not IsToolNameChar(AName[I]) then
      Exit(False);
  Result := True;
end;

function MCPSanitizeToolName(const AName: string): string;
var
  I: Integer;
begin
  Result := AName;
  for I := 1 to Length(Result) do
    if not IsToolNameChar(Result[I]) then
      Result[I] := '_';
  if Length(Result) > MCP_TOOL_NAME_MAX_LEN then
    SetLength(Result, MCP_TOOL_NAME_MAX_LEN);
end;

{ TMCPCapabilities }

function TMCPCapabilities.ToJSON: TJDOJsonObject;
begin
  Result := TJDOJsonObject.Create;
  if SupportsTools then
    Result.O['tools'] := TJDOJsonObject.Create;
  if SupportsResources then
    Result.O['resources'] := TJDOJsonObject.Create;
  if SupportsPrompts then
    Result.O['prompts'] := TJDOJsonObject.Create;
end;

{ TMCPServerInfo }

function TMCPServerInfo.ToJSON: TJDOJsonObject;
begin
  Result := TJDOJsonObject.Create;
  Result.S['name'] := Name;
  Result.S['version'] := Version;
end;

{ TMCPClientInfo }

procedure TMCPClientInfo.FromJSON(const AJSON: TJDOJsonObject);
begin
  if AJSON <> nil then
  begin
    Name := AJSON.S['name'];
    Version := AJSON.S['version'];
  end;
end;

end.
