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

program MCPServerUnitTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MVCFramework,
  MVCFramework.Logger,
  MVCFramework.DotEnv,
  MVCFramework.Commons,
  MVCFramework.Serializer.Commons,
  MVCFramework.Signal,
  MVCFramework.Server.Intf,
  MVCFramework.Server.Factory,
  MVCFramework.Server.HTTPS.TaurusTLS,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Stdio,
  // MUST be listed BEFORE provider units: reads --transport from the
  // command line and suppresses stdout logging when stdio is selected.
  MVCFramework.MCP.TransportConf,
  MCPTestToolsU in 'MCPTestToolsU.pas',
  MCPTestResourcesU in 'MCPTestResourcesU.pas',
  MCPTestPromptsU in 'MCPTestPromptsU.pas',
  MCPConformanceProvidersU in 'MCPConformanceProvidersU.pas',
  BootConfigU in 'BootConfigU.pas',
  EngineConfigU in 'EngineConfigU.pas';

{$R *.res}

// ---------------------------------------------------------------------------
// RunServer: Indy Direct backend with optional HTTPS via TaurusTLS.
// ---------------------------------------------------------------------------
procedure RunServer(APort: Integer);
var
  LEngine: TMVCEngine;
  LServer: IMVCServer;
  LProtocol: string;
begin
  LEngine := TMVCEngine.Create(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.APPLICATION_JSON;
      Config[TMVCConfigKey.DefaultContentCharset] := TMVCConstants.DEFAULT_CONTENT_CHARSET;
      Config[TMVCConfigKey.ExposeServerSignature] := 'false';
    end);
  try
    ConfigureEngine(LEngine);
    LServer := TMVCServerFactory.CreateIndyDirect(LEngine);
    LServer.KeepAlive := dotEnv.Env('dmvc.indy.keep_alive', True);
    LServer.MaxConnections := dotEnv.Env('dmvc.webbroker.max_connections', 0);
    LServer.ListenQueue := dotEnv.Env('dmvc.indy.listen_queue', 500);

    if dotEnv.Env('https.enabled', False) then
    begin
      LogI('HTTPS is enabled');
      LServer.HTTPSConfigurator := TaurusTLSIndyConfigurator();
      LServer.UseHTTPS := True;
      LServer.CertFile := dotEnv.Env('https.cert.cacert', 'certificates\localhost.crt');
      LServer.KeyFile := dotEnv.Env('https.cert.privkey', 'certificates\localhost.key');
      LServer.CertPassword := dotEnv.Env('https.cert.password', '');
      LProtocol := 'https';
    end
    else
    begin
      LogW('HTTPS is available but CURRENTLY NOT ENABLED');
      LProtocol := 'http';
    end;

    LServer.Listen(APort);

    LogI('MCP Test Server listening on ' + LProtocol + '://localhost:' + APort.ToString + '/mcp');
    LogI('Server type: Indy Direct');
    LogI('Registered tools: ' + TMCPServer.Instance.Tools.Count.ToString);
    LogI('Registered resources: ' + TMCPServer.Instance.Resources.Count.ToString);
    LogI('Registered prompts: ' + TMCPServer.Instance.Prompts.Count.ToString);
    LogI('Press Ctrl+C to shut down.');

    WaitForTerminationSignal;
    EnterInShutdownState;
    LServer.Stop;
    LServer := nil;
  finally
    LEngine.Free;
  end;
end;

procedure RunStdio;
var
  LTransport: TMCPStdioTransport;
begin
  LTransport := TMCPStdioTransport.Create(TMCPServer.Instance);
  try
    LTransport.Run;
  finally
    LTransport.Free;
  end;
end;

function ParseTransport: string;
var
  I: Integer;
begin
  Result := 'http'; // default
  for I := 1 to ParamCount do
  begin
    if SameText(ParamStr(I), '--transport') and (I < ParamCount) then
    begin
      Result := LowerCase(ParamStr(I + 1));
      Exit;
    end;
    if ParamStr(I).StartsWith('--transport=', True) then
    begin
      Result := LowerCase(Copy(ParamStr(I), Length('--transport=') + 1, MaxInt));
      Exit;
    end;
  end;
end;

var
  LTransport: string;
begin
  ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;
  MVCSerializeNulls := True;
  MVCNameCaseDefault := TMVCNameCase.ncCamelCase;

  // BootConfigU.Boot: dotEnv + LoggerPro logger + profiler.
  // The logger selects loggerpro.stdio.json (file-only) in stdio mode
  // via MVCFramework.MCP.TransportConf.MCPTransportIsStdio.
  Boot;

  TMCPServer.Instance.ServerName := 'MCPServerUnitTest';
  TMCPServer.Instance.ServerVersion := '1.0.0';

  LTransport := ParseTransport;

  if LTransport = 'stdio' then
  begin
    try
      RunStdio;
    except
      on E: Exception do
        System.Write(ErrOutput, E.ClassName + ': ' + E.Message + sLineBreak);
    end;
  end
  else if LTransport = 'http' then
  begin
    LogI('** MCP Server Unit Test ** powered by DMVCFramework build ' + DMVCFRAMEWORK_VERSION);
    try
      RunServer(dotEnv.Env('dmvc.server.port', 8080));
    except
      on E: Exception do
        LogF(E.ClassName + ': ' + E.Message);
    end;
  end
  else
  begin
    WriteLn(ErrOutput, 'Unknown transport: ' + LTransport);
    WriteLn(ErrOutput, 'Usage: MCPServerUnitTest [--transport http|stdio]');
    ExitCode := 1;
  end;
end.
