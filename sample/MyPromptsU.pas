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
// ***************************************************************************

unit MyPromptsU;

interface

uses
  JsonDataObjects,
  MVCFramework.MCP.PromptProvider,
  MVCFramework.MCP.Attributes;

type
  TMyPrompts = class(TMCPPromptProvider)
  public
    [MCPPrompt('code_review', 'Generates a code review prompt for the given source code')]
    [MCPPromptArg('code', 'The source code to review', True)]
    [MCPPromptArg('language', 'Programming language (e.g. Pascal, Python)', False)]
    function CodeReview(const Arguments: TJDOJsonObject): TMCPPromptResult;

    [MCPPrompt('summarize', 'Generates a summarization prompt for the given text')]
    [MCPPromptArg('text', 'The text to summarize', True)]
    [MCPPromptArg('max_words', 'Maximum number of words for the summary', False)]
    function Summarize(const Arguments: TJDOJsonObject): TMCPPromptResult;
  end;

implementation

uses
  System.SysUtils, MVCFramework.MCP.Server;

{ TMyPrompts }

function TMyPrompts.CodeReview(const Arguments: TJDOJsonObject): TMCPPromptResult;
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

function TMyPrompts.Summarize(const Arguments: TJDOJsonObject): TMCPPromptResult;
var
  LText, LMaxWords: string;
begin
  LText := Arguments.S['text'];
  LMaxWords := Arguments.S['max_words'];
  if LMaxWords.IsEmpty then
    LMaxWords := '100';

  Result := TMCPPromptResult.Create(
    'Text summarization',
    [
      PromptMessage('user',
        'Please summarize the following text in at most ' + LMaxWords +
        ' words:' + sLineBreak + sLineBreak + LText)
    ]);
end;

initialization
  TMCPServer.Instance.RegisterPromptProvider(TMyPrompts);

end.
