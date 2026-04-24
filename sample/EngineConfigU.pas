// ***************************************************************************
//
// MCP Server for Delphi and Delphi MVC Framework
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
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
  // Provider units self-register in their `initialization` sections: just
  // listing them here is enough to activate them.
  MyToolsU,
  MyResourcesU,
  MyPromptsU;

procedure ConfigureEngine(AEngine: TMVCEngine);
begin
  // Controllers
  // MCP session termination controller (HTTP DELETE on /mcp) per spec 2025-03-26.
  AEngine.AddController(TMCPSessionController);
  // Controllers - END

  // Published objects
  // MCP endpoint at "/mcp". The factory creates a fresh TMCPEndpoint per
  // request; registered tools / resources / prompts are discovered
  // automatically via RTTI at startup (see MyToolsU).
  AEngine.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');
  // Published objects - END
end;

end.
