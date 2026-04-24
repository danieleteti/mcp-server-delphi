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

unit MyResourcesU;

interface

uses
  MVCFramework.MCP.ResourceProvider,
  MVCFramework.MCP.Attributes;

type
  TMyResources = class(TMCPResourceProvider)
  public
    [MCPResource('config://app/settings', 'Application Settings',
      'Returns the current application configuration as JSON', 'application/json')]
    function GetAppSettings(const URI: string): TMCPResourceResult;

    [MCPResource('file:///docs/about.txt', 'About',
      'Returns information about this MCP server', 'text/plain')]
    function GetAbout(const URI: string): TMCPResourceResult;

    [MCPResource('file:///assets/icon.png', 'Application Icon',
      'Returns a 1x1 placeholder PNG image', 'image/png')]
    function GetIcon(const URI: string): TMCPResourceResult;
  end;

implementation

uses
  System.SysUtils, MVCFramework.MCP.Server;

{ TMyResources }

function TMyResources.GetAppSettings(const URI: string): TMCPResourceResult;
begin
  Result := TMCPResourceResult.Text(
    URI,
    '{'                                                   + sLineBreak +
    '  "serverName": "DMVCFrameworkMCPServerSample",'     + sLineBreak +
    '  "version": "1.0.0",'                               + sLineBreak +
    '  "features": ["tools", "resources", "prompts"]'     + sLineBreak +
    '}',
    'application/json');
end;

function TMyResources.GetAbout(const URI: string): TMCPResourceResult;
begin
  Result := TMCPResourceResult.Text(
    URI,
    'MCP Server Sample for DMVCFramework' + sLineBreak +
    '===================================' + sLineBreak +
    'Exposes tools, resources and prompts to MCP-compatible AI clients ' +
    'via the /mcp endpoint (HTTP) or stdio transport.',
    'text/plain');
end;

function TMyResources.GetIcon(const URI: string): TMCPResourceResult;
begin
  // 1x1 red pixel PNG, base64-encoded.
  Result := TMCPResourceResult.Blob(
    URI,
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==',
    'image/png');
end;

initialization
  TMCPServer.Instance.RegisterResourceProvider(TMyResources);

end.
