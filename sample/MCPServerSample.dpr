// ***************************************************************************
//
// Delphi MVC Framework
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


program MCPServerSample;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Web.ReqMulti,
  Web.WebReq,
  Web.WebBroker,
  MVCFramework,
  MVCFramework.Logger,
  MVCFramework.DotEnv,
  MVCFramework.Commons,
  MVCFramework.Serializer.Commons,
  IdContext,
  IdHTTPWebBrokerBridge,
  TaurusTLS,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Stdio,
  MVCFramework.Signal,
  MyToolsU in 'MyToolsU.pas',
  WebModuleU in 'WebModuleU.pas' {MyWebModule: TWebModule};

{$R *.res}

type
  TTLSHandler = class
    procedure OnGetSSLPassword(aSender: TObject; var aPassword: String; const aIsWrite: Boolean; var aOk: Boolean);
    procedure OnQuerySSLPort(aPort: Word; var vUseSSL: boolean);
    procedure ConfigureTLS(aServer: TIdHTTPWebBrokerBridge);
  end;

{ TTLSHandler }

procedure TTLSHandler.ConfigureTLS(aServer: TIdHTTPWebBrokerBridge);
var
  lTaurusTLSHandler: TTaurusTLSServerIOHandler;
begin
  lTaurusTLSHandler := TTaurusTLSServerIOHandler.Create(aServer);
  lTaurusTLSHandler.SSLOptions.Mode := sslmServer;
  lTaurusTLSHandler.DefaultCert.PublicKey := dotEnv.Env('https.cert.cacert', 'certificates\localhost.crt');
  lTaurusTLSHandler.DefaultCert.PrivateKey := dotEnv.Env('https.cert.privkey', 'certificates\localhost.key');
  lTaurusTLSHandler.OnGetPassword := OnGetSSLPassword;
  lTaurusTLSHandler.OnGetPassword := OnGetSSLPassword;
  aServer.IOHandler := lTaurusTLSHandler;
  aServer.OnQuerySSLPort := OnQuerySSLPort;
end;

procedure TTLSHandler.OnGetSSLPassword(aSender: TObject; var aPassword: String; const aIsWrite: Boolean; var aOk: Boolean);
begin
  aPassword := dotEnv.Env('https.cert.password', '');
  aOk := True;
end;

procedure TTLSHandler.OnQuerySSLPort(aPort: Word; var vUseSSL: boolean);
begin
  vUseSSL := true;
end;

procedure RunServer(aPort: Integer);
var
  LServer: TIdHTTPWebBrokerBridge;
  LSSLHandler: TTLSHandler;
  LProtocol: String;
begin
  LProtocol := 'http';
  LServer := TIdHTTPWebBrokerBridge.Create(nil);
  try
    LServer.OnParseAuthentication := TMVCParseAuthentication.OnParseAuthentication;
    LServer.DefaultPort := APort;
    LServer.KeepAlive := dotEnv.Env('dmvc.indy.keep_alive', True);
    LServer.MaxConnections := dotEnv.Env('dmvc.webbroker.max_connections', 0);
    LServer.ListenQueue := dotEnv.Env('dmvc.indy.listen_queue', 500);
    LSSLHandler := TTLSHandler.Create;
    try
      if dotEnv.Env('https.enabled', false) then //enable if you want HTTPS support
      begin
        LogI('HTTPS is enabled');
        LSSLHandler.ConfigureTLS(LServer);
        LProtocol := 'https';
      end
      else
      begin
        LogW('HTTPS is available but CURRENTLY NOT ENABLED');
      end;
      LServer.Active := True;
      LogI('MCP Server listening on ' + LProtocol + '://localhost:' + APort.ToString + '/mcp');
      LogI('MCP Server started. Press Ctrl+C to shut down.');
      WaitForTerminationSignal;
      EnterInShutdownState;
      LServer.Active := False;
    finally
      LSSLHandler.Free;
    end;
  finally
    LServer.Free;
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
  UseConsoleLogger := True;
  UseLoggerVerbosityLevel := TLogLevel.levNormal;

  TMCPServer.Instance.ServerName := 'DMVCFrameworkMCPServerSample';
  TMCPServer.Instance.ServerVersion := '1.0.0';

  LTransport := ParseTransport;

  if LTransport = 'stdio' then
  begin
    UseConsoleLogger := False;  // stdout is reserved for JSON-RPC
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
      if WebRequestHandler <> nil then
        WebRequestHandler.WebModuleClass := WebModuleClass;
      WebRequestHandlerProc.MaxConnections := dotEnv.Env('dmvc.handler.max_connections', 1024);
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
