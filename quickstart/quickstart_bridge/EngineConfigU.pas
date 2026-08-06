// ***************************************************************************
//
// MCP Bridge Quickstart - Engine configuration
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
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
  MVCFramework.MCP.Bridge,
  BooksControllerU;

procedure ConfigureEngine(AEngine: TMVCEngine);
begin
  // Step 1: register business controllers
  AEngine.AddController(TBooksController);

  // Step 2: scan the engine and create MCP bridge tools.
  // RegisterFromEngine is called HERE, after the business controllers are
  // added but before TMCPSessionController, so that the session controller
  // is not exposed as a bridge tool (it would create a delete_mcp tool that
  // terminates the session, which is not what we want).
  TMCPServer.Instance.RegisterFromEngine(AEngine, 'http://localhost:8080');

  // Step 3: MCP infrastructure (added AFTER the scan)
  AEngine.AddController(TMCPSessionController);

  // Step 4: publish the MCP endpoint at /mcp
  AEngine.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');
end;

end.
