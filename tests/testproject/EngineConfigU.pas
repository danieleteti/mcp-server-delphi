// ***************************************************************************
//
// MCP Server for Delphi and Delphi MVC Framework - Test Server
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0 (the "License");
//
// ***************************************************************************

unit EngineConfigU;

interface

uses
  MVCFramework;

procedure ConfigureEngine(AEngine: TMVCEngine);

implementation

uses
  MVCFramework.MCP.Server,
  // Test provider units self-register in their initialization sections.
  // Just listing them here is enough to activate the providers.
  MCPTestToolsU,
  MCPTestResourcesU,
  MCPTestPromptsU,
  MCPConformanceProvidersU;

procedure ConfigureEngine(AEngine: TMVCEngine);
begin
  // Controllers
  // MCP session termination controller (HTTP DELETE on /mcp) per spec 2025-03-26.
  AEngine.AddController(TMCPSessionController);
  // Controllers - END

  // Published objects
  AEngine.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');
  // Published objects - END
end;

end.
