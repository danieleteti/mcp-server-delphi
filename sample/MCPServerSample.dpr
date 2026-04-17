// ***************************************************************************
//
// MCP Server for Delphi and Delphi MVC Framework
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
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


program MCPServerSample;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MVCFramework,
  MVCFramework.Logger,
  MVCFramework.DotEnv,
  MVCFramework.Commons,
  MVCFramework.Serializer.Commons,
  MVCFramework.Server.Intf,
  MVCFramework.Server.Factory,
  // Pulled in only because https.enabled may be set. If HTTPS is never
  // needed this uses line can be removed together with the TaurusTLS
  // dependency.
  MVCFramework.Server.HTTPS.TaurusTLS,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Stdio,
  MVCFramework.Signal,
  MVCFramework.MCP.TransportConf, { MUST be before provider units to suppress stdout logging in stdio mode }
  MyToolsU in 'MyToolsU.pas';

{$R *.res}

// ---------------------------------------------------------------------------
// BuildEngine: configures a TMVCEngine bound to the Indy Direct backend.
//
// TMVCEngine.CreateForIndyDirect is the speaking constructor for the
// Indy Direct transport  no TWebModule, no WebBroker bridge. The engine
// owns the request pipeline directly.
// ---------------------------------------------------------------------------
function BuildEngine: TMVCEngine;
begin
  Result := TMVCEngine.CreateForIndyDirect(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.APPLICATION_JSON;
      Config[TMVCConfigKey.DefaultContentCharset] := TMVCConstants.DEFAULT_CONTENT_CHARSET;
      Config[TMVCConfigKey.ExposeServerSignature] := dotEnv.Env('dmvc.expose_server_signature', 'false');
    end);

  // MCP session termination (HTTP DELETE on /mcp) per spec 2025-03-26.
  Result.AddController(TMCPSessionController);

  // Publish the MCP endpoint at "/mcp". The factory creates a fresh
  // TMCPEndpoint per request; registered tools / resources / prompts
  // are discovered automatically via RTTI.
  Result.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');
end;

// ---------------------------------------------------------------------------
// RunServer: starts the HTTP (optionally HTTPS) transport on Indy Direct.
//
// HTTPS is opt-in via the https.enabled env var. When enabled, the
// IMVCServer's HTTPSConfigurator is set to TaurusTLSIndyConfigurator,
// which installs a TaurusTLSServerIOHandler on the underlying
// TIdHTTPServer using CertFile / KeyFile / CertPassword properties.
// Swapping to a different TLS stack is a one-line change (configurator).
// ---------------------------------------------------------------------------
procedure RunServer(APort: Integer);
var
  LEngine: TMVCEngine;
  LServer: IMVCServer;
  LProtocol: string;
begin
  LEngine := BuildEngine;
  try
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

    LogI('MCP Server listening on ' + LProtocol + '://localhost:' + APort.ToString + '/mcp');
    LogI('MCP Server started. Press Ctrl+C to shut down.');

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
  // ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;
  MVCSerializeNulls := True;
  MVCNameCaseDefault := TMVCNameCase.ncCamelCase;

  { Parse transport early: in stdio mode, console logger must be disabled
    before any LogI calls to prevent log output on stdout }
  LTransport := ParseTransport;
  if LTransport = 'stdio' then
    UseConsoleLogger := False
  else
    UseConsoleLogger := True;
  UseLoggerVerbosityLevel := TLogLevel.levNormal;

  TMCPServer.Instance.ServerName := 'DMVCFrameworkMCPServerSample';
  TMCPServer.Instance.ServerVersion := '1.0.0';

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
    LogI('** MCP Server Sample ** powered by DMVCFramework build ' + DMVCFRAMEWORK_VERSION);
    try
      RunServer(dotEnv.Env('dmvc.server.port', 443));
    except
      on E: Exception do
        LogF(E.ClassName + ': ' + E.Message);
    end;
  end
  else
  begin
    WriteLn(ErrOutput, 'Unknown transport: ' + LTransport);
    WriteLn(ErrOutput, 'Usage: MCPServerSample [--transport http|stdio]');
    ExitCode := 1;
  end;
end.
