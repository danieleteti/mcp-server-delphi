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
// RESOURCE PROVIDER
// =================
// Resources are data that AI assistants can read. Each resource is identified
// by a URI and has a MIME type. Think of them as "files" or "endpoints" that
// the AI can browse.
//
// Common use cases:
//   - Expose application configuration
//   - Provide reference documentation
//   - Share data files (JSON, CSV, text)
//   - Serve images or binary assets
//
// HOW TO ADD A NEW RESOURCE:
//   1. Add a public method to TMyResources (or create a new TMCPResourceProvider)
//   2. Decorate it with [MCPResource(URI, Name, Description, MimeType)]
//   3. The method receives the requested URI as a parameter
//   4. Return a TMCPResourceResult (Text or Blob)
//
// URI SCHEMES (conventions, not enforced):
//   config://...    --> application configuration
//   file:///...     --> file-like resources
//   db://...        --> database-sourced data
//   api://...       --> API-sourced data
//   You can use any scheme you want.
//
// RESULT FACTORY METHODS:
//   TMCPResourceResult.Text(URI, Content, MimeType)   --> text content
//   TMCPResourceResult.Blob(URI, Base64Data, MimeType) --> binary content
//
// ***************************************************************************

unit ResourceProviderU;

interface

uses
  MVCFramework.MCP.ResourceProvider,
  MVCFramework.MCP.Attributes;

type
  // -------------------------------------------------------------------------
  // TMyResources - Your MCP resource provider
  //
  // Add, modify, or remove methods below to define the resources your AI
  // clients can read. Each method decorated with [MCPResource] becomes a
  // readable resource in the MCP protocol.
  // -------------------------------------------------------------------------
  TMyResources = class(TMCPResourceProvider)
  public

    // A JSON resource — the AI can read this to understand your app's config.
    // URI: config://app/settings
    // MimeType: application/json
    [MCPResource('config://app/settings', 'Application Settings',
      'Returns the current application configuration as JSON', 'application/json')]
    function GetAppSettings(const URI: string): TMCPResourceResult;

    // A plain text resource.
    // URI: file:///docs/about.txt
    // MimeType: text/plain (this is the default if you omit the 4th parameter)
    [MCPResource('file:///docs/about.txt', 'About',
      'Returns information about this MCP server', 'text/plain')]
    function GetAbout(const URI: string): TMCPResourceResult;

    // A binary resource (image).
    // Binary resources use TMCPResourceResult.Blob() with base64-encoded data.
    // URI: file:///assets/icon.png
    // MimeType: image/png
    [MCPResource('file:///assets/icon.png', 'Application Icon',
      'Returns the application icon as a PNG image', 'image/png')]
    function GetIcon(const URI: string): TMCPResourceResult;

  end;

implementation

uses
  MVCFramework.MCP.Server;

{ TMyResources }

function TMyResources.GetAppSettings(const URI: string): TMCPResourceResult;
begin
  // In a real application, you would read this from a config file,
  // database, or your application's runtime state.
  Result := TMCPResourceResult.Text(
    URI,  // always pass the URI back in the response
    '{'                                                    + sLineBreak +
    '  "serverName": "MyMCPServer",'                       + sLineBreak +
    '  "version": "1.0.0",'                                + sLineBreak +
    '  "features": ["tools", "resources", "prompts"],'     + sLineBreak +
    '  "maxConnections": 100'                              + sLineBreak +
    '}',
    'application/json'
  );
end;

function TMyResources.GetAbout(const URI: string): TMCPResourceResult;
begin
  Result := TMCPResourceResult.Text(
    URI,
    'MCP Quick Start Server' + sLineBreak +
    '======================' + sLineBreak +
    'This is a sample MCP server built with DMVCFramework.' + sLineBreak +
    'It demonstrates tools, resources, and prompts.' + sLineBreak +
    sLineBreak +
    'Customize the provider units to add your own capabilities!',
    'text/plain'
  );
end;

function TMyResources.GetIcon(const URI: string): TMCPResourceResult;
begin
  // This is a minimal 1x1 red PNG pixel encoded in base64.
  // In a real application, you would load a file from disk:
  //   LStream := TFileStream.Create('icon.png', fmOpenRead);
  //   LBase64 := TNetEncoding.Base64.EncodeBytesToString(LStream);
  Result := TMCPResourceResult.Blob(
    URI,
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==',
    'image/png'
  );
end;

// ---------------------------------------------------------------------------
// AUTO-REGISTRATION
// ---------------------------------------------------------------------------
initialization
  TMCPServer.Instance.RegisterResourceProvider(TMyResources);

end.
