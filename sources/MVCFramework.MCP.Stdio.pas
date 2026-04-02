// ***************************************************************************
//
// MCP Server Library for DMVCFramework
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

unit MVCFramework.MCP.Stdio;

interface

uses
  MVCFramework.MCP.RequestHandler;

type
  TMCPStdioTransport = class
  private
    FHandler: TMCPRequestHandler;
    procedure LogStderr(const AMessage: string);
  public
    constructor Create(AServer: TObject);
    destructor Destroy; override;
    procedure Run;  // Blocks until stdin EOF
  end;

implementation

uses
  System.SysUtils, System.Classes,
  JsonDataObjects,
  MVCFramework.MCP.Server;

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create(AServer: TObject);
begin
  inherited Create;
  FHandler := TMCPRequestHandler.Create(AServer);
end;

destructor TMCPStdioTransport.Destroy;
begin
  FHandler.Free;
  inherited;
end;

procedure TMCPStdioTransport.LogStderr(const AMessage: string);
begin
  System.Write(ErrOutput, AMessage + sLineBreak);
end;

procedure TMCPStdioTransport.Run;
var
  LLine: string;
  LRequest: TJDOJsonObject;
  LResponse: TJDOJsonObject;
  LErrorResponse: TJDOJsonObject;
  LHasId: Boolean;
begin
  LogStderr('MCP stdio transport started');
  while not EOF(Input) do
  begin
    ReadLn(Input, LLine);
    if LLine.Trim.IsEmpty then
      Continue;

    LRequest := nil;
    LResponse := nil;
    try
      try
        LRequest := TJDOJsonObject.Parse(LLine) as TJDOJsonObject;
      except
        on E: Exception do
        begin
          { Parse error - build JSON manually to ensure id is null }
          WriteLn(Output, '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error: ' +
            E.Message.Replace('\', '\\').Replace('"', '\"') + '"},"id":null}');
          Flush(Output);
          Continue;
        end;
      end;

      LHasId := LRequest.Contains('id');

      try
        FHandler.ValidateSession(LRequest.S['method']);
      except
        on E: EMCPSessionError do
        begin
          if LHasId then
          begin
            LErrorResponse := TJDOJsonObject.Create;
            try
              LErrorResponse.S['jsonrpc'] := '2.0';
              LErrorResponse.O['error'].I['code'] := -32600;
              LErrorResponse.O['error'].S['message'] := E.Message;
              { Copy id preserving type }
              case LRequest.Types['id'] of
                jdtString:
                  LErrorResponse.S['id'] := LRequest.S['id'];
                jdtInt:
                  LErrorResponse.I['id'] := LRequest.I['id'];
                jdtLong:
                  LErrorResponse.L['id'] := LRequest.L['id'];
              else
                LErrorResponse.S['id'] := LRequest.S['id'];
              end;
              WriteLn(Output, LErrorResponse.ToJSON(True));
              Flush(Output);
            finally
              LErrorResponse.Free;
            end;
          end
          else
            LogStderr('Session error on notification: ' + E.Message);
          Continue;
        end;
      end;

      try
        LResponse := FHandler.HandleRequest(LRequest);
        if LResponse <> nil then
        begin
          WriteLn(Output, LResponse.ToJSON(True));
          Flush(Output);
        end;
      except
        on E: Exception do
        begin
          if LHasId then
          begin
            LErrorResponse := TJDOJsonObject.Create;
            try
              LErrorResponse.S['jsonrpc'] := '2.0';
              LErrorResponse.O['error'].I['code'] := -32603;
              LErrorResponse.O['error'].S['message'] := 'Internal error: ' + E.Message;
              { Copy id preserving type }
              case LRequest.Types['id'] of
                jdtString:
                  LErrorResponse.S['id'] := LRequest.S['id'];
                jdtInt:
                  LErrorResponse.I['id'] := LRequest.I['id'];
                jdtLong:
                  LErrorResponse.L['id'] := LRequest.L['id'];
              else
                LErrorResponse.S['id'] := LRequest.S['id'];
              end;
              WriteLn(Output, LErrorResponse.ToJSON(True));
              Flush(Output);
            finally
              LErrorResponse.Free;
            end;
          end
          else
            LogStderr('Error processing notification: ' + E.Message);
        end;
      end;
    finally
      LRequest.Free;
      LResponse.Free;
    end;
  end;
  LogStderr('MCP stdio transport: stdin closed');
end;

end.
