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

unit MVCFramework.MCP.PromptProvider;

interface

uses
  JsonDataObjects, System.SysUtils;

type
  TMCPPromptMessage = record
    Role: string;
    ContentType: string;    // 'text', 'image', or 'resource'
    Text: string;           // used for text content
    Data: string;           // used for image content (base64)
    MimeType: string;       // used for image and resource content
    ResourceURI: string;    // used for resource content
    ResourceText: string;   // used for resource content
  end;

  TMCPPromptResult = record
  private
    FDescription: string;
    FMessages: TArray<TMCPPromptMessage>;
  public
    class function Create(const ADescription: string; const AMessages: TArray<TMCPPromptMessage>): TMCPPromptResult; static;
    function ToJSON: TJDOJsonObject;
  end;

  TMCPPromptProvider = class
  public
    constructor Create; virtual;
    destructor Destroy; override;
  end;

  TMCPPromptProviderClass = class of TMCPPromptProvider;

function PromptMessage(const ARole, AText: string): TMCPPromptMessage;
function PromptImageMessage(const ARole, ABase64Data, AMimeType: string): TMCPPromptMessage;
function PromptResourceMessage(const ARole, AResourceURI, AResourceText, AMimeType: string): TMCPPromptMessage;

implementation

function PromptMessage(const ARole, AText: string): TMCPPromptMessage;
begin
  Result.Role := ARole;
  Result.ContentType := 'text';
  Result.Text := AText;
  Result.Data := '';
  Result.MimeType := '';
  Result.ResourceURI := '';
  Result.ResourceText := '';
end;

function PromptImageMessage(const ARole, ABase64Data, AMimeType: string): TMCPPromptMessage;
begin
  Result.Role := ARole;
  Result.ContentType := 'image';
  Result.Data := ABase64Data;
  Result.MimeType := AMimeType;
  Result.Text := '';
  Result.ResourceURI := '';
  Result.ResourceText := '';
end;

function PromptResourceMessage(const ARole, AResourceURI, AResourceText, AMimeType: string): TMCPPromptMessage;
begin
  Result.Role := ARole;
  Result.ContentType := 'resource';
  Result.ResourceURI := AResourceURI;
  Result.ResourceText := AResourceText;
  Result.MimeType := AMimeType;
  Result.Text := '';
  Result.Data := '';
end;

{ TMCPPromptResult }

class function TMCPPromptResult.Create(const ADescription: string; const AMessages: TArray<TMCPPromptMessage>): TMCPPromptResult;
begin
  Result.FDescription := ADescription;
  Result.FMessages := AMessages;
end;

function TMCPPromptResult.ToJSON: TJDOJsonObject;
var
  LMessages: TJDOJsonArray;
  LMsg: TJDOJsonObject;
  I: Integer;
begin
  Result := TJDOJsonObject.Create;
  if not FDescription.IsEmpty then
    Result.S['description'] := FDescription;
  LMessages := Result.A['messages'];
  for I := 0 to High(FMessages) do
  begin
    LMsg := LMessages.AddObject;
    LMsg.S['role'] := FMessages[I].Role;
    if SameText(FMessages[I].ContentType, 'image') then
    begin
      LMsg.O['content'].S['type'] := 'image';
      LMsg.O['content'].S['data'] := FMessages[I].Data;
      LMsg.O['content'].S['mimeType'] := FMessages[I].MimeType;
    end
    else if SameText(FMessages[I].ContentType, 'resource') then
    begin
      LMsg.O['content'].S['type'] := 'resource';
      LMsg.O['content'].O['resource'].S['uri'] := FMessages[I].ResourceURI;
      LMsg.O['content'].O['resource'].S['mimeType'] := FMessages[I].MimeType;
      LMsg.O['content'].O['resource'].S['text'] := FMessages[I].ResourceText;
    end
    else
    begin
      LMsg.O['content'].S['type'] := FMessages[I].ContentType;
      LMsg.O['content'].S['text'] := FMessages[I].Text;
    end;
  end;
end;

{ TMCPPromptProvider }

constructor TMCPPromptProvider.Create;
begin
  inherited Create;
end;

destructor TMCPPromptProvider.Destroy;
begin
  inherited;
end;

end.
