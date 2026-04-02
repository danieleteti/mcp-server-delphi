// ***************************************************************************
//
// MCP Server for DMVCFramework
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

unit MCPConformanceProvidersU;

interface

uses
  JsonDataObjects,
  MVCFramework.MCP.ToolProvider,
  MVCFramework.MCP.ResourceProvider,
  MVCFramework.MCP.PromptProvider,
  MVCFramework.MCP.Attributes;

type
  TConformanceTools = class(TMCPToolProvider)
  public
    [MCPTool('test_simple_text', 'Returns a simple text response for conformance testing')]
    function TestSimpleText: TMCPToolResult;

    [MCPTool('test_image_content', 'Returns a test image for conformance testing')]
    function TestImageContent: TMCPToolResult;

    [MCPTool('test_audio_content', 'Returns test audio content for conformance testing')]
    function TestAudioContent: TMCPToolResult;

    [MCPTool('test_embedded_resource', 'Returns an embedded resource for conformance testing')]
    function TestEmbeddedResource: TMCPToolResult;

    [MCPTool('test_multiple_content_types', 'Returns multiple content types for conformance testing')]
    function TestMultipleContentTypes: TMCPToolResult;

    [MCPTool('test_error_handling', 'Returns an error for conformance testing')]
    function TestErrorHandling: TMCPToolResult;
  end;

  TConformanceResources = class(TMCPResourceProvider)
  public
    [MCPResource('test://static-text', 'Static text resource for conformance testing', 'text/plain')]
    function StaticText: TMCPResourceResult;

    [MCPResource('test://static-binary', 'Static binary resource for conformance testing', 'image/png')]
    function StaticBinary: TMCPResourceResult;
  end;

  TConformancePrompts = class(TMCPPromptProvider)
  public
    [MCPPrompt('test_simple_prompt', 'A simple prompt for conformance testing')]
    function TestSimplePrompt(const Arguments: TJDOJsonObject): TMCPPromptResult;

    [MCPPrompt('test_prompt_with_arguments', 'A prompt with arguments for conformance testing')]
    [MCPPromptArg('arg1', 'First argument', True)]
    [MCPPromptArg('arg2', 'Second argument', True)]
    function TestPromptWithArguments(const Arguments: TJDOJsonObject): TMCPPromptResult;

    [MCPPrompt('test_prompt_with_embedded_resource', 'A prompt with an embedded resource for conformance testing')]
    [MCPPromptArg('resourceUri', 'URI of the resource to embed', True)]
    function TestPromptWithEmbeddedResource(const Arguments: TJDOJsonObject): TMCPPromptResult;

    [MCPPrompt('test_prompt_with_image', 'A prompt with an image for conformance testing')]
    function TestPromptWithImage(const Arguments: TJDOJsonObject): TMCPPromptResult;
  end;

implementation

uses
  System.SysUtils,
  MVCFramework.MCP.Server;

const
  RED_PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==';
  MINIMAL_WAV_BASE64 = 'UklGRi4AAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQoAAAD//w==';

{ TConformanceTools }

function TConformanceTools.TestSimpleText: TMCPToolResult;
begin
  Result := TMCPToolResult.Text('This is a simple text response for testing.');
end;

function TConformanceTools.TestImageContent: TMCPToolResult;
begin
  Result := TMCPToolResult.Image(RED_PNG_BASE64, 'image/png');
end;

function TConformanceTools.TestAudioContent: TMCPToolResult;
begin
  Result := TMCPToolResult.Audio(MINIMAL_WAV_BASE64, 'audio/wav');
end;

function TConformanceTools.TestEmbeddedResource: TMCPToolResult;
begin
  Result := TMCPToolResult.Resource('test://embedded-resource',
    'This is an embedded resource content.', 'text/plain');
end;

function TConformanceTools.TestMultipleContentTypes: TMCPToolResult;
begin
  Result := TMCPToolResult.Text('Multiple content types test:')
    .AddImage(RED_PNG_BASE64, 'image/png')
    .AddResource('test://mixed-content-resource', '{"test":"data","value":123}', 'application/json');
end;

function TConformanceTools.TestErrorHandling: TMCPToolResult;
begin
  Result := TMCPToolResult.Error('This tool intentionally returns an error for testing');
end;

{ TConformanceResources }

function TConformanceResources.StaticText: TMCPResourceResult;
begin
  Result := TMCPResourceResult.Text('test://static-text',
    'This is the content of the static text resource.', 'text/plain');
end;

function TConformanceResources.StaticBinary: TMCPResourceResult;
begin
  Result := TMCPResourceResult.Blob('test://static-binary',
    RED_PNG_BASE64, 'image/png');
end;

{ TConformancePrompts }

function TConformancePrompts.TestSimplePrompt(const Arguments: TJDOJsonObject): TMCPPromptResult;
begin
  Result := TMCPPromptResult.Create(
    '',
    [PromptMessage('user', 'This is a simple prompt for testing.')]);
end;

function TConformancePrompts.TestPromptWithArguments(const Arguments: TJDOJsonObject): TMCPPromptResult;
var
  LArg1, LArg2: string;
begin
  LArg1 := Arguments.S['arg1'];
  LArg2 := Arguments.S['arg2'];
  Result := TMCPPromptResult.Create(
    '',
    [PromptMessage('user',
      'Prompt with arguments: arg1=''' + LArg1 + ''', arg2=''' + LArg2 + '''')]);
end;

function TConformancePrompts.TestPromptWithEmbeddedResource(const Arguments: TJDOJsonObject): TMCPPromptResult;
var
  LResourceURI: string;
begin
  LResourceURI := Arguments.S['resourceUri'];
  Result := TMCPPromptResult.Create(
    '',
    [
      PromptResourceMessage('user', LResourceURI,
        'Embedded resource content for testing.', 'text/plain'),
      PromptMessage('user', 'Please process the embedded resource above.')
    ]);
end;

function TConformancePrompts.TestPromptWithImage(const Arguments: TJDOJsonObject): TMCPPromptResult;
begin
  Result := TMCPPromptResult.Create(
    '',
    [
      PromptImageMessage('user', RED_PNG_BASE64, 'image/png'),
      PromptMessage('user', 'Please analyze the image above.')
    ]);
end;

initialization
  TMCPServer.Instance.RegisterToolProvider(TConformanceTools);
  TMCPServer.Instance.RegisterResourceProvider(TConformanceResources);
  TMCPServer.Instance.RegisterPromptProvider(TConformancePrompts);

end.
