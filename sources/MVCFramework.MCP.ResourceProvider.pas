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
  private type
    IContentHolder = interface
      function GetContents: TJDOJsonArray;
      procedure ReleaseContents;
    end;
    TContentHolder = class(TInterfacedObject, IContentHolder)
    private
      FContents: TJDOJsonArray;
    public
      constructor Create(AContents: TJDOJsonArray);
      destructor Destroy; override;
      function GetContents: TJDOJsonArray;
      procedure ReleaseContents;
    end;
  private
    FHolder: IContentHolder;
  public
    class function Text(const AURI, AText: string;
      const AMimeType: string = 'text/plain'): TMCPResourceResult; static;
    class function Blob(const AURI, ABase64Data: string;
      const AMimeType: string = 'application/octet-stream'): TMCPResourceResult; static;
    function ToJSON: TJDOJsonObject;
  end;

  TMCPResourceProvider = class
  public
    constructor Create; virtual;
    destructor Destroy; override;
  end;

  TMCPResourceProviderClass = class of TMCPResourceProvider;

implementation

{ TMCPResourceResult.TContentHolder }

constructor TMCPResourceResult.TContentHolder.Create(AContents: TJDOJsonArray);
begin
  inherited Create;
  FContents := AContents;
end;

destructor TMCPResourceResult.TContentHolder.Destroy;
begin
  FContents.Free;
  inherited;
end;

function TMCPResourceResult.TContentHolder.GetContents: TJDOJsonArray;
begin
  Result := FContents;
end;

procedure TMCPResourceResult.TContentHolder.ReleaseContents;
begin
  FContents := nil;
end;

{ TMCPResourceResult }

class function TMCPResourceResult.Text(const AURI, AText: string;
  const AMimeType: string): TMCPResourceResult;
var
  LContents: TJDOJsonArray;
  LItem: TJDOJsonObject;
begin
  LContents := TJDOJsonArray.Create;
  LItem := LContents.AddObject;
  LItem.S['uri'] := AURI;
  LItem.S['mimeType'] := AMimeType;
  LItem.S['text'] := AText;
  Result.FHolder := TContentHolder.Create(LContents);
end;

class function TMCPResourceResult.Blob(const AURI, ABase64Data: string;
  const AMimeType: string): TMCPResourceResult;
var
  LContents: TJDOJsonArray;
  LItem: TJDOJsonObject;
begin
  LContents := TJDOJsonArray.Create;
  LItem := LContents.AddObject;
  LItem.S['uri'] := AURI;
  LItem.S['mimeType'] := AMimeType;
  LItem.S['blob'] := ABase64Data;
  Result.FHolder := TContentHolder.Create(LContents);
end;

function TMCPResourceResult.ToJSON: TJDOJsonObject;
var
  LContents: TJDOJsonArray;
begin
  Result := TJDOJsonObject.Create;
  if FHolder <> nil then
  begin
    LContents := FHolder.GetContents;
    FHolder.ReleaseContents;
    Result.A['contents'] := LContents;
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
