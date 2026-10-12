unit ProbeToolsU;

interface

uses
  MVCFramework.MCP.ToolProvider, MVCFramework.MCP.Attributes;

type
  TProbeTools = class(TMCPToolProvider)
  public
    [MCPTool('probe_echo', 'Echoes the input')]
    function Echo([MCPParam('Text to echo')] const Value: string): TMCPToolResult;
    [MCPTool('probe.dotted', 'A tool whose name is outside the provider alphabet')]
    function Dotted: TMCPToolResult;
  end;

implementation

uses
  MVCFramework.MCP.Server;

function TProbeTools.Echo(const Value: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(Value);
end;

function TProbeTools.Dotted: TMCPToolResult;
begin
  Result := TMCPToolResult.Text('dotted');
end;

initialization
  TMCPServer.Instance.RegisterToolProvider(TProbeTools);

end.
