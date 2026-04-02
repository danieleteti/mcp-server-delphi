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

unit MCPTestPromptsU;

interface

uses
  JsonDataObjects,
  MVCFramework.MCP.PromptProvider,
  MVCFramework.MCP.Attributes;

type
  TTestPrompts = class(TMCPPromptProvider)
  public
    [MCPPrompt('code_review', 'Generates a code review prompt for the given code')]
    [MCPPromptArg('code', 'The source code to review', True)]
    [MCPPromptArg('language', 'Programming language of the code', False)]
    function CodeReview(const Arguments: TJDOJsonObject): TMCPPromptResult;

    [MCPPrompt('summarize', 'Generates a summarization prompt')]
    [MCPPromptArg('text', 'The text to summarize', True)]
    [MCPPromptArg('maxLength', 'Maximum summary length in words', False)]
    function Summarize(const Arguments: TJDOJsonObject): TMCPPromptResult;

    [MCPPrompt('translate', 'Generates a translation prompt')]
    [MCPPromptArg('text', 'The text to translate', True)]
    [MCPPromptArg('sourceLang', 'Source language', False)]
    [MCPPromptArg('targetLang', 'Target language', True)]
    function Translate(const Arguments: TJDOJsonObject): TMCPPromptResult;
  end;

implementation

uses
  System.SysUtils,
  MVCFramework.MCP.Server;

{ TTestPrompts }

function TTestPrompts.CodeReview(const Arguments: TJDOJsonObject): TMCPPromptResult;
var
  LCode, LLang: string;
begin
  LCode := Arguments.S['code'];
  LLang := Arguments.S['language'];
  if LLang.IsEmpty then
    LLang := 'unknown language';

  Result := TMCPPromptResult.Create(
    'Code review for ' + LLang + ' code',
    [
      PromptMessage('user',
        'Please review the following ' + LLang + ' code for bugs, ' +
        'performance issues, and best practices:' + sLineBreak + sLineBreak + LCode),
      PromptMessage('assistant',
        'I will review the code focusing on correctness, performance, ' +
        'readability, and adherence to best practices.')
    ]);
end;

function TTestPrompts.Summarize(const Arguments: TJDOJsonObject): TMCPPromptResult;
var
  LText, LMaxLen: string;
begin
  LText := Arguments.S['text'];
  LMaxLen := Arguments.S['maxLength'];
  if LMaxLen.IsEmpty then
    LMaxLen := '100';

  Result := TMCPPromptResult.Create(
    'Text summarization',
    [
      PromptMessage('user',
        'Please summarize the following text in at most ' + LMaxLen +
        ' words:' + sLineBreak + sLineBreak + LText)
    ]);
end;

function TTestPrompts.Translate(const Arguments: TJDOJsonObject): TMCPPromptResult;
var
  LText, LSource, LTarget: string;
begin
  LText := Arguments.S['text'];
  LSource := Arguments.S['sourceLang'];
  LTarget := Arguments.S['targetLang'];
  if LSource.IsEmpty then
    LSource := 'auto-detect';

  Result := TMCPPromptResult.Create(
    'Translation from ' + LSource + ' to ' + LTarget,
    [
      PromptMessage('user',
        'Translate the following text from ' + LSource + ' to ' + LTarget +
        ':' + sLineBreak + sLineBreak + LText),
      PromptMessage('assistant',
        'Here is the translation:')
    ]);
end;

initialization
  TMCPServer.Instance.RegisterPromptProvider(TTestPrompts);

end.
