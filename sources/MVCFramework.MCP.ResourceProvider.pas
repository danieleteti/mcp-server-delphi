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

unit MVCFramework.MCP.ResourceProvider;

interface

uses
  JsonDataObjects, System.SysUtils;

type
  TMCPResourceResult = record
  private
    FContents: TJDOJsonArray;
  public
    class function Text(const AURI, AText: string; const AMimeType: string = 'text/plain'): TMCPResourceResult; static;
    class function Blob(const AURI, ABase64Data: string; const AMimeType: string = 'application/octet-stream'): TMCPResourceResult; static;
    function ToJSON: TJDOJsonObject;
  end;

  TMCPResourceProvider = class
  public
    constructor Create; virtual;
    destructor Destroy; override;
  end;

  TMCPResourceProviderClass = class of TMCPResourceProvider;

implementation

{ TMCPResourceResult }

class function TMCPResourceResult.Text(const AURI, AText: string; const AMimeType: string): TMCPResourceResult;
var
  LItem: TJDOJsonObject;
begin
  Result.FContents := TJDOJsonArray.Create;
  LItem := Result.FContents.AddObject;
  LItem.S['uri'] := AURI;
  LItem.S['mimeType'] := AMimeType;
  LItem.S['text'] := AText;
end;

class function TMCPResourceResult.Blob(const AURI, ABase64Data: string; const AMimeType: string): TMCPResourceResult;
var
  LItem: TJDOJsonObject;
begin
  Result.FContents := TJDOJsonArray.Create;
  LItem := Result.FContents.AddObject;
  LItem.S['uri'] := AURI;
  LItem.S['mimeType'] := AMimeType;
  LItem.S['blob'] := ABase64Data;
end;

function TMCPResourceResult.ToJSON: TJDOJsonObject;
begin
  Result := TJDOJsonObject.Create;
  if FContents <> nil then
  begin
    Result.A['contents'] := FContents;
    FContents := nil; { Ownership transferred }
  end
  else
    Result.A['contents'] := TJDOJsonArray.Create;
end;

{ TMCPResourceProvider }

constructor TMCPResourceProvider.Create;
begin
  inherited Create;
end;

destructor TMCPResourceProvider.Destroy;
begin
  inherited;
end;

end.
