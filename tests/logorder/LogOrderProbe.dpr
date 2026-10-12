program LogOrderProbe;

{$APPTYPE CONSOLE}

uses
  ProbeToolsU in 'ProbeToolsU.pas',
  System.SysUtils,
  MVCFramework.Logger,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Stdio;

var
  LTransport: TMCPStdioTransport;
begin
  // What an application does after its units are initialised: no console.
  UseConsoleLogger := False;
  LTransport := TMCPStdioTransport.Create(TMCPServer.Instance);
  try
    LTransport.Run;
  finally
    LTransport.Free;
  end;
end.
