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
  MCP_SERVER_LIBRARY_VERSION = '0.8.0';
  MCP_PROTOCOL_VERSION = '2025-03-26';
  MCP_ENDPOINT = '/mcp';
  MCP_SESSION_HEADER = 'Mcp-Session-Id';

type
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
