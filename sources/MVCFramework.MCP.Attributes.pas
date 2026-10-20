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

unit MVCFramework.MCP.Attributes;

interface

{$SCOPEDENUMS ON}
type
  TMCPParamPresence = (Required, Optional);
{$SCOPEDENUMS OFF}

type
  { Marks a method as an MCP tool }
  MCPToolAttribute = class(TCustomAttribute)
  private
    FName: string;
    FDescription: string;
  public
    constructor Create(const AName, ADescription: string);
    property Name: string read FName;
    property Description: string read FDescription;
  end;

  { Human-readable name of a tool, shown by clients instead of the technical
    name (spec 2025-06-18). Goes in the tool's "title" and "annotations.title". }
  MCPToolTitleAttribute = class(TCustomAttribute)
  private
    FTitle: string;
  public
    constructor Create(const ATitle: string);
    property Title: string read FTitle;
  end;

  { Tool annotations (hints for the client, not a security boundary: they come
    from the server, so a client must not trust them from a server it does not
    trust). Combine as needed on the tool method. }
  { The tool does not change anything. A host can run it without asking. }
  MCPReadOnlyAttribute = class(TCustomAttribute);
  { The tool changes things but never deletes or overwrites (default is: it may). }
  MCPNonDestructiveAttribute = class(TCustomAttribute);
  { Calling it again with the same arguments has no further effect. }
  MCPIdempotentAttribute = class(TCustomAttribute);
  { The tool touches only this server's own data, not the open world
    (the web, other systems). }
  MCPClosedWorldAttribute = class(TCustomAttribute);

  { Placed on a method parameter to provide its MCP description and required flag.
    Name and type are discovered automatically from the Delphi parameter itself. }
  MCPParamAttribute = class(TCustomAttribute)
  private
    FDescription: string;
    FRequired: Boolean;
  public
    constructor Create(const ADescription: string; ARequired: TMCPParamPresence = TMCPParamPresence.Required);
    property Description: string read FDescription;
    property Required: Boolean read FRequired;
  end;

  { Marks a method as an MCP resource }
  MCPResourceAttribute = class(TCustomAttribute)
  private
    FURI: string;
    FName: string;
    FDescription: string;
    FMimeType: string;
  public
    constructor Create(const AURI, AName, ADescription: string; const AMimeType: string = 'text/plain');
    property URI: string read FURI;
    property Name: string read FName;
    property Description: string read FDescription;
    property MimeType: string read FMimeType;
  end;

  { Marks a method as an MCP prompt }
  MCPPromptAttribute = class(TCustomAttribute)
  private
    FName: string;
    FDescription: string;
  public
    constructor Create(const AName, ADescription: string);
    property Name: string read FName;
    property Description: string read FDescription;
  end;

  { Describes an argument for an MCP prompt }
  MCPPromptArgAttribute = class(TCustomAttribute)
  private
    FName: string;
    FDescription: string;
    FRequired: Boolean;
  public
    constructor Create(const AName, ADescription: string; ARequired: TMCPParamPresence = TMCPParamPresence.Optional);
    property Name: string read FName;
    property Description: string read FDescription;
    property Required: Boolean read FRequired;
  end;

implementation

{ MCPToolAttribute }

constructor MCPToolAttribute.Create(const AName, ADescription: string);
begin
  inherited Create;
  FName := AName;
  FDescription := ADescription;
end;

{ MCPToolTitleAttribute }

constructor MCPToolTitleAttribute.Create(const ATitle: string);
begin
  inherited Create;
  FTitle := ATitle;
end;

{ MCPParamAttribute }

constructor MCPParamAttribute.Create(const ADescription: string; ARequired: TMCPParamPresence);
begin
  inherited Create;
  FDescription := ADescription;
  FRequired := ARequired = TMCPParamPresence.Required;
end;

{ MCPResourceAttribute }

constructor MCPResourceAttribute.Create(const AURI, AName, ADescription: string; const AMimeType: string);
begin
  inherited Create;
  FURI := AURI;
  FName := AName;
  FDescription := ADescription;
  FMimeType := AMimeType;
end;

{ MCPPromptAttribute }

constructor MCPPromptAttribute.Create(const AName, ADescription: string);
begin
  inherited Create;
  FName := AName;
  FDescription := ADescription;
end;

{ MCPPromptArgAttribute }

constructor MCPPromptArgAttribute.Create(const AName, ADescription: string; ARequired: TMCPParamPresence);
begin
  inherited Create;
  FName := AName;
  FDescription := ADescription;
  FRequired := ARequired = TMCPParamPresence.Required;
end;

end.
