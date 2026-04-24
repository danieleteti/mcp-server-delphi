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

unit BootConfigU;

interface

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
  dotEnvConfigure(
    function: IMVCDotEnv
    begin
      Result := NewDotEnv
                 .UseStrategy(TMVCDotEnvPriority.FileThenEnv)
                 .UseProfile('test')
                 .UseProfile('prod')
                 .Build();
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
{$IF CompilerVersion >= 34}
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
