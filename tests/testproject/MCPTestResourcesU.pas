// ***************************************************************************
//
// MCP Server for DMVCFramework
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

unit MCPTestResourcesU;

interface

uses
  MVCFramework.MCP.ResourceProvider,
  MVCFramework.MCP.Attributes;

type
  TTestResources = class(TMCPResourceProvider)
  public
    [MCPResource('config://app/settings', 'Application Settings',
      'Returns the current application configuration as JSON', 'application/json')]
    function GetAppSettings(const URI: string): TMCPResourceResult;

    [MCPResource('file:///docs/readme.txt', 'Readme',
      'Returns the application readme text', 'text/plain')]
    function GetReadme(const URI: string): TMCPResourceResult;

    [MCPResource('file:///assets/logo.png', 'Logo Image',
      'Returns a small test logo as base64 blob', 'image/png')]
    function GetLogo(const URI: string): TMCPResourceResult;
  end;

implementation

uses
  MVCFramework.MCP.Server;

{ TTestResources }

function TTestResources.GetAppSettings(const URI: string): TMCPResourceResult;
begin
  Result := TMCPResourceResult.Text(URI,
    '{"serverName":"MCPServerUnitTest","version":"1.0.0","debug":true}',
    'application/json');
end;

function TTestResources.GetReadme(const URI: string): TMCPResourceResult;
begin
  Result := TMCPResourceResult.Text(URI,
    'MCP Server for DMVCFramework - Unit Test Application',
    'text/plain');
end;

function TTestResources.GetLogo(const URI: string): TMCPResourceResult;
begin
  // Minimal 1x1 red PNG pixel (base64)
  Result := TMCPResourceResult.Blob(URI,
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==',
    'image/png');
end;

initialization
  TMCPServer.Instance.RegisterResourceProvider(TTestResources);

end.
