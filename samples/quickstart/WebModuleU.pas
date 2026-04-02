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
// WEB MODULE
// ==========
// This unit is the bridge between DMVCFramework's HTTP engine and the MCP
// protocol handler. You normally don't need to change anything here.
//
// Two things happen in WebModuleCreate:
//   1. TMCPSessionController is registered to handle session cleanup (DELETE)
//   2. The MCP endpoint is published at "/mcp" via PublishObject
//
// That's all it takes — the MCP library handles everything else:
//   - JSON-RPC 2.0 dispatch
//   - Session management (create, validate, expire)
//   - Automatic discovery of your tools, resources, and prompts via RTTI
//
// ***************************************************************************

unit WebModuleU;

interface

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
  MVCFramework;

type
  TMyWebModule = class(TWebModule)
    procedure WebModuleCreate(Sender: TObject);
    procedure WebModuleDestroy(Sender: TObject);
  private
    fMVC: TMVCEngine;
  end;

var
  WebModuleClass: TComponentClass = TMyWebModule;

implementation

{$R *.dfm}

uses
  MVCFramework.Commons,
  MVCFramework.MCP.Server;

procedure TMyWebModule.WebModuleCreate(Sender: TObject);
begin
  fMVC := TMVCEngine.Create(Self,
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.APPLICATION_JSON;
    end);

  // Register the session controller BEFORE PublishObject.
  // This handles HTTP DELETE requests for MCP session termination,
  // as required by the MCP specification (2025-03-26).
  fMVC.AddController(TMCPSessionController);

  // Publish the MCP endpoint at "/mcp".
  // The factory function creates a new TMCPEndpoint instance for each request.
  // All registered tools, resources, and prompts are automatically available.
  fMVC.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');
end;

procedure TMyWebModule.WebModuleDestroy(Sender: TObject);
begin
  fMVC.Free;
end;

end.
