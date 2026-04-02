// ***************************************************************************
//
// MCP Server for DMVCFramework - Quick Start
//
// Copyright (c) 2010-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// PROMPT PROVIDER
// ===============
// Prompts are reusable message templates. When an AI client requests a prompt,
// your server returns a pre-built conversation (one or more messages) that the
// AI uses as context for its response.
//
// Common use cases:
//   - Code review templates
//   - Translation workflows
//   - Summarization instructions
//   - Domain-specific analysis templates
//
// HOW TO ADD A NEW PROMPT:
//   1. Add a public method to TMyPrompts (or create a new TMCPPromptProvider)
//   2. Decorate it with [MCPPrompt('prompt_name', 'Description')]
//   3. Add [MCPPromptArg('name', 'description', Required)] for each argument
//   4. The method receives arguments as a TJDOJsonObject
//   5. Return a TMCPPromptResult with one or more messages
//
// MESSAGE TYPES:
//   PromptMessage('user', 'text...')
//     --> a text message from the "user" or "assistant" role
//
//   PromptImageMessage('user', Base64Data, MimeType)
//     --> a message containing an image
//
//   PromptResourceMessage('user', ResourceURI, ResourceText, MimeType)
//     --> a message containing an embedded resource
//
// ***************************************************************************

unit PromptProviderU;

interface

uses
  JsonDataObjects,
  MVCFramework.MCP.PromptProvider,
  MVCFramework.MCP.Attributes;

type
  // -------------------------------------------------------------------------
  // TMyPrompts - Your MCP prompt provider
  //
  // Add, modify, or remove methods below to define the prompts your AI
  // clients can use. Each method decorated with [MCPPrompt] becomes an
  // available prompt in the MCP protocol.
  // -------------------------------------------------------------------------
  TMyPrompts = class(TMCPPromptProvider)
  public

    // A prompt with one required and one optional argument.
    // Arguments are declared with [MCPPromptArg]:
    //   - 'code' is required (True) — the AI must provide it
    //   - 'language' is optional (False) — defaults to empty string if omitted
    [MCPPrompt('code_review', 'Generates a code review prompt for the given source code')]
    [MCPPromptArg('code', 'The source code to review', True)]
    [MCPPromptArg('language', 'Programming language of the code (e.g. Pascal, Python)', False)]
    function CodeReview(const Arguments: TJDOJsonObject): TMCPPromptResult;

    // A simple prompt with one required argument.
    [MCPPrompt('summarize', 'Generates a summarization prompt for the given text')]
    [MCPPromptArg('text', 'The text to summarize', True)]
    [MCPPromptArg('max_words', 'Maximum number of words for the summary', False)]
    function Summarize(const Arguments: TJDOJsonObject): TMCPPromptResult;

    // A multi-message prompt that sets up a conversation flow.
    // The assistant message "primes" the AI with the expected behavior.
    [MCPPrompt('translate', 'Generates a translation prompt')]
    [MCPPromptArg('text', 'The text to translate', True)]
    [MCPPromptArg('source_lang', 'Source language (auto-detect if omitted)', False)]
    [MCPPromptArg('target_lang', 'Target language', True)]
    function Translate(const Arguments: TJDOJsonObject): TMCPPromptResult;

  end;

implementation

uses
  System.SysUtils,
  MVCFramework.MCP.Server;

{ TMyPrompts }

function TMyPrompts.CodeReview(const Arguments: TJDOJsonObject): TMCPPromptResult;
var
  LCode, LLang: string;
begin
  // Read arguments from the JSON object.
  // Use .S['key'] to get string values — returns empty string if not present.
  LCode := Arguments.S['code'];
  LLang := Arguments.S['language'];
  if LLang.IsEmpty then
    LLang := 'unknown language';

  // Build the prompt result.
  // TMCPPromptResult.Create takes:
  //   - Description: short text explaining what this prompt does
  //   - Messages: array of TMCPPromptMessage records
  Result := TMCPPromptResult.Create(
    'Code review for ' + LLang + ' code',   // description
    [
      // The "user" message contains the actual request
      PromptMessage('user',
        'Please review the following ' + LLang + ' code for bugs, ' +
        'performance issues, and best practices:' + sLineBreak +
        sLineBreak +
        LCode),

      // The "assistant" message sets the tone for the response.
      // This is optional but helps guide the AI's behavior.
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

function TMyPrompts.Translate(const Arguments: TJDOJsonObject): TMCPPromptResult;
var
  LText, LSource, LTarget: string;
begin
  LText := Arguments.S['text'];
  LSource := Arguments.S['source_lang'];
  LTarget := Arguments.S['target_lang'];
  if LSource.IsEmpty then
    LSource := 'auto-detect';

  Result := TMCPPromptResult.Create(
    'Translation from ' + LSource + ' to ' + LTarget,
    [
      // User message: the translation request
      PromptMessage('user',
        'Translate the following text from ' + LSource + ' to ' + LTarget +
        ':' + sLineBreak + sLineBreak + LText),

      // Assistant message: primes the AI to respond immediately with translation
      PromptMessage('assistant',
        'Here is the translation:')
    ]);
end;

// ---------------------------------------------------------------------------
// AUTO-REGISTRATION
// ---------------------------------------------------------------------------
initialization
  TMCPServer.Instance.RegisterPromptProvider(TMyPrompts);

end.
