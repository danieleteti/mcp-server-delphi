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

unit MCPBridgeTestControllerU;

interface

uses
  MVCFramework,
  MVCFramework.Commons;

type
  [MVCPath('/bridge-test')]
  TMCPBridgeTestController = class(TMVCController)
  public
    [MVCPath]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Returns a fixed greeting')]
    procedure GetGreeting;

    [MVCPath('/($name)')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Returns a greeting for the given name')]
    procedure GetGreetingByName(const name: string);

    [MVCPath('/search')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Searches items by keyword')]
    procedure SearchItems(
      const [MVCFromQueryString('q')] q: string;
      const [MVCFromQueryString('limit', '10')] limit: Integer
    );

    [MVCPath('/echo')]
    [MVCHTTPMethod([httpPOST])]
    [MVCDoc('Echoes the request body')]
    procedure PostEcho(const [MVCFromBody] body: string);
  end;

implementation

uses
  System.SysUtils;

procedure TMCPBridgeTestController.GetGreeting;
begin
  Render('{"message":"hello from bridge-test"}');
end;

procedure TMCPBridgeTestController.GetGreetingByName(const name: string);
begin
  Render('{"message":"hello ' + name + '"}');
end;

procedure TMCPBridgeTestController.SearchItems(const q: string; const limit: Integer);
var
  LLimit: Integer;
begin
  LLimit := limit;
  if LLimit <= 0 then LLimit := 10;
  Render('{"q":"' + q + '","limit":' + LLimit.ToString + ',"results":[]}');
end;

procedure TMCPBridgeTestController.PostEcho(const body: string);
begin
  Render(body);
end;

end.
