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

unit BootConfigU;

interface

/// Runs all startup configuration for the MCP server: dotEnv, LoggerPro
/// logger and DMVC profiler. Call this once, as the first statement of the
/// .dpr begin..end block, before any LogI/LogW/LogE call.
///
/// The logger selects between loggerpro.json (console + file) and
/// loggerpro.stdio.json (file only) based on MCPTransportIsStdio, so
/// launching the server with --transport stdio keeps stdout clean for
/// MCP JSON-RPC traffic.
procedure Boot;

implementation

uses
  System.SysUtils,
  System.JSON,
  LoggerPro.Config,
  LoggerPro,
  LoggerPro.Builder,
  LoggerPro.ConsoleAppender,
  LoggerPro.FileAppender,
  MVCFramework.Logger.ColorConsoleRenderer,
  MVCFramework.DotEnv,
  MVCFramework.Commons,
  MVCFramework.Logger,
  MVCFramework.MCP.TransportConf;

procedure ConfigDotEnv;
begin
  // Register the dotEnv delegate before the logger reads from it.
  dotEnvConfigure(
    function: IMVCDotEnv
    begin
      Result := NewDotEnv
                 .UseStrategy(TMVCDotEnvPriority.FileThenEnv)
                                       //if available, by default, loads default environment (.env)
                 .UseProfile('test') //if available loads the test environment (.env.test)
                 .UseProfile('prod') //if available loads the prod environment (.env.prod)
                 .Build();             //uses the executable folder to look for .env* files
    end);
end;

procedure ConfigLogger;
var
  lBuilder: ILoggerProBuilder;
  lConfigFile: string;
begin
  // In stdio mode stdout is reserved for MCP JSON-RPC messages: pick a
  // file-only logger config so nothing leaks on stdout.
  if MCPTransportIsStdio then
    lConfigFile := dotEnv.Env('logger.config.file.stdio', 'loggerpro.stdio.json')
  else
    lConfigFile := dotEnv.Env('logger.config.file', 'loggerpro.json');

  lBuilder := TLoggerProConfig.BuilderFromJSONFile(lConfigFile);
  SetDefaultLogger(lBuilder.Build);
end;

procedure ConfigProfiler;
begin
{$IF CompilerVersion >= 34} //SYDNEY+
  if dotEnv.Env('dmvc.profiler.enabled', False) then
  begin
    Profiler.ProfileLogger := Log;
    Profiler.WarningThreshold := dotEnv.Env('dmvc.profiler.warning_threshold', 1000);
    Profiler.LogsOnlyIfOverThreshold := dotEnv.Env('dmvc.profiler.logs_only_over_threshold', True);
  end;
{$ENDIF}
end;

procedure Boot;
begin
  ConfigDotEnv;
  ConfigLogger;
  ConfigProfiler;
end;

end.
