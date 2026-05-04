// ***************************************************************************
//
// MCP Server for DMVCFramework - TMCPOpenAIAgent compliance test
//
// Copyright (c) 2010-2026 Daniele Teti
//
// https://github.com/danieleteti/delphimvcframework
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// Console smoke test for MVCFramework.MCP.OpenAIAgent.
//
// Embeds a deterministic fake LLM (DMVCFramework controller responding to
// /v1/chat/completions) that inspects the request shape and produces canned
// responses, so the agent loop can be exercised without external network
// dependencies. Pairs with the MCP testproject server (pre-started on
// http://localhost:8080/mcp by default) to provide real tools.
//
// Usage:
//   MCPAgentTest.exe [--mcp-url http://localhost:8080/mcp] [--llm-port 9091]
//
// ***************************************************************************

program MCPAgentTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.SyncObjs,
  System.Generics.Collections,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Server.Intf,
  MVCFramework.Server.Factory,
  MVCFramework.MCP.Client,
  MVCFramework.MCP.OpenAIAgent;

// ──────────────────────────────────────────────────────────────────────────
// Test runner
// ──────────────────────────────────────────────────────────────────────────

type
  TTestRunner = class
  private
    FPassed, FFailed: Integer;
    FErrors: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Ok(const AName: string);
    procedure Fail(const AName, AReason: string);
    procedure Section(const AName: string);
    function Summary: Boolean;
    property Passed: Integer read FPassed;
    property Failed: Integer read FFailed;
  end;

constructor TTestRunner.Create;
begin
  inherited;
  FErrors := TStringList.Create;
end;

destructor TTestRunner.Destroy;
begin
  FErrors.Free;
  inherited;
end;

procedure TTestRunner.Ok(const AName: string);
begin
  Inc(FPassed);
  WriteLn('  [PASS] ', AName);
end;

procedure TTestRunner.Fail(const AName, AReason: string);
begin
  Inc(FFailed);
  FErrors.Add(AName + ': ' + AReason);
  WriteLn('  [FAIL] ', AName, ' -- ', AReason);
end;

procedure TTestRunner.Section(const AName: string);
begin
  WriteLn;
  WriteLn('--- ', AName, ' ---');
end;

function TTestRunner.Summary: Boolean;
var
  I: Integer;
begin
  WriteLn;
  WriteLn(StringOfChar('=', 60));
  WriteLn(Format('Results: %d/%d passed, %d failed',
    [FPassed, FPassed + FFailed, FFailed]));
  if FErrors.Count > 0 then
  begin
    WriteLn;
    WriteLn('Failures:');
    for I := 0 to FErrors.Count - 1 do
      WriteLn('  - ', FErrors[I]);
  end;
  WriteLn(StringOfChar('=', 60));
  Result := FFailed = 0;
end;

// ──────────────────────────────────────────────────────────────────────────
// Fake LLM behavior controller (shared state captured per request)
//
// Two switchable modes set by tests via globals:
//   - tmDispatchOnce: first turn returns a single tool_call for
//     reverse_string("hello"), subsequent turn(s) return the final content.
//   - tmAlwaysToolCall: every turn returns a tool_call, used to exercise
//     the MaxTurns safety net.
//
// The last received request body is stashed for assertions on what the
// agent actually sent (system prompt, headers, etc.).
// ──────────────────────────────────────────────────────────────────────────

type
  TFakeMode = (tmDispatchOnce, tmAlwaysToolCall);

var
  G_Mode: TFakeMode = tmDispatchOnce;
  G_LastBody: string = '';
  G_LastSeenSystem: string = '';
  G_LastReferer: string = '';
  G_LastXTitle: string = '';
  G_RequestCount: Integer = 0;
  G_RequestLock: TCriticalSection;

type
  [MVCPath('/v1')]
  TFakeLLMController = class(TMVCController)
  public
    [MVCPath('/chat/completions')]
    [MVCHTTPMethod([httpPOST])]
    procedure ChatCompletions;
  end;

procedure TFakeLLMController.ChatCompletions;
var
  LBody: string;
  LReq, LMsg, LResp, LChoice, LMessage, LUsage: TJSONObject;
  LMessages, LChoices, LToolCalls: TJSONArray;
  LRoleVal: TJSONValue;
  LIsToolFollowUp: Boolean;
  LToolCall, LFunc: TJSONObject;
  I: Integer;
begin
  // Capture request body and headers for test assertions.
  LBody := Context.Request.Body;
  G_RequestLock.Enter;
  try
    G_LastBody := LBody;
    G_LastReferer := Context.Request.Headers['HTTP-Referer'];
    G_LastXTitle  := Context.Request.Headers['X-Title'];
    Inc(G_RequestCount);
  finally
    G_RequestLock.Leave;
  end;

  // Look for a role:"system" first message and a trailing role:"tool".
  LIsToolFollowUp := False;
  G_LastSeenSystem := '';
  LReq := TJSONObject.ParseJSONValue(LBody) as TJSONObject;
  try
    if Assigned(LReq) and (LReq.GetValue('messages') is TJSONArray) then
    begin
      LMessages := LReq.GetValue('messages') as TJSONArray;
      // Inspect first message for system prompt.
      if (LMessages.Count > 0) and (LMessages.Items[0] is TJSONObject) then
      begin
        LMsg := TJSONObject(LMessages.Items[0]);
        LRoleVal := LMsg.FindValue('role');
        if Assigned(LRoleVal) and (LRoleVal is TJSONString)
           and (TJSONString(LRoleVal).Value = 'system') then
          G_LastSeenSystem := LMsg.GetValue<string>('content', '');
      end;
      // Last message: tool follow-up?
      for I := LMessages.Count - 1 downto 0 do
      begin
        if LMessages.Items[I] is TJSONObject then
        begin
          LRoleVal := TJSONObject(LMessages.Items[I]).FindValue('role');
          if Assigned(LRoleVal) and (LRoleVal is TJSONString)
             and (TJSONString(LRoleVal).Value = 'tool') then
            LIsToolFollowUp := True;
          Break;
        end;
      end;
    end;
  finally
    LReq.Free;
  end;

  // Build the response.
  LResp := TJSONObject.Create;
  try
    LResp.AddPair('id', 'chatcmpl-fake');
    LResp.AddPair('object', 'chat.completion');
    LResp.AddPair('model', 'fake-model');

    LChoices := TJSONArray.Create;
    LResp.AddPair('choices', LChoices);

    LChoice := TJSONObject.Create;
    LChoices.AddElement(LChoice);
    LChoice.AddPair('index', TJSONNumber.Create(0));

    LMessage := TJSONObject.Create;
    LChoice.AddPair('message', LMessage);
    LMessage.AddPair('role', 'assistant');

    if (G_Mode = tmDispatchOnce) and LIsToolFollowUp then
    begin
      // Final answer turn.
      LMessage.AddPair('content', 'reversed: olleh');
      LChoice.AddPair('finish_reason', 'stop');
    end
    else
    begin
      // Tool-call turn: ask the agent to call reverse_string("hello").
      LMessage.AddPair('content', TJSONNull.Create);
      LToolCalls := TJSONArray.Create;
      LMessage.AddPair('tool_calls', LToolCalls);

      LToolCall := TJSONObject.Create;
      LToolCalls.AddElement(LToolCall);
      LToolCall.AddPair('id', 'call_fake_' + IntToStr(G_RequestCount));
      LToolCall.AddPair('type', 'function');

      LFunc := TJSONObject.Create;
      LToolCall.AddPair('function', LFunc);
      LFunc.AddPair('name', 'reverse_string');
      LFunc.AddPair('arguments', '{"Value":"hello"}');

      LChoice.AddPair('finish_reason', 'tool_calls');
    end;

    // Token accounting (canned values, monotonically increasing).
    LUsage := TJSONObject.Create;
    LResp.AddPair('usage', LUsage);
    LUsage.AddPair('prompt_tokens',     TJSONNumber.Create(50));
    LUsage.AddPair('completion_tokens', TJSONNumber.Create(20));
    LUsage.AddPair('total_tokens',      TJSONNumber.Create(70));

    Render(LResp);
    LResp := nil; // Render takes ownership? In DMVC, Render(TObject) does not — keep, see below.
  finally
    // Render in DMVCFramework with TJSONObject overload serializes and frees
    // the object. If LResp was already nilled above, this no-ops; otherwise
    // we don't need to free here. Trust the framework's semantics.
    LResp.Free;
  end;
end;

// ──────────────────────────────────────────────────────────────────────────
// Fake LLM lifecycle
// ──────────────────────────────────────────────────────────────────────────

var
  G_FakeLLMEngine: TMVCEngine = nil;

function StartFakeLLM(APort: Integer): IMVCServer;
begin
  G_FakeLLMEngine := TMVCEngine.Create(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.APPLICATION_JSON;
      Config[TMVCConfigKey.DefaultContentCharset] := TMVCConstants.DEFAULT_CONTENT_CHARSET;
      Config[TMVCConfigKey.ExposeServerSignature] := 'false';
    end);
  G_FakeLLMEngine.AddController(TFakeLLMController);
  Result := TMVCServerFactory.CreateIndyDirect(G_FakeLLMEngine);
  Result.Listen(APort);
end;

// ──────────────────────────────────────────────────────────────────────────
// Argument parsing
// ──────────────────────────────────────────────────────────────────────────

function ParseStringArg(const AKey, ADefault: string): string;
var
  I: Integer;
begin
  Result := ADefault;
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), '--' + AKey) and (I < ParamCount) then
    begin
      Result := ParamStr(I + 1);
      Exit;
    end;
end;

function ParseIntArg(const AKey: string; ADefault: Integer): Integer;
var
  S: string;
begin
  S := ParseStringArg(AKey, IntToStr(ADefault));
  Result := StrToIntDef(S, ADefault);
end;

// ──────────────────────────────────────────────────────────────────────────
// Test cases
// ──────────────────────────────────────────────────────────────────────────

procedure TestSingleToolCall(const AMCPURL: string; ALLMPort: Integer; AR: TTestRunner);
var
  LAgent: TMCPOpenAIAgent;
  LMessages: TJSONArray;
  LUserMsg: TJSONObject;
  LResult: TMCPAgentResult;
begin
  AR.Section('Single tool call');
  G_Mode := tmDispatchOnce;
  G_RequestCount := 0;
  G_LastSeenSystem := '';
  G_LastReferer := '';
  G_LastXTitle := '';

  LAgent := TMCPOpenAIAgent.Create(
    AMCPURL,
    'fake-api-key',
    'fake-model',
    Format('http://127.0.0.1:%d/v1', [ALLMPort]));
  try
    LAgent.MaxTurns := 5;
    LAgent.SystemPrompt := 'You are a helpful test agent.';
    LAgent.HTTPReferer := 'https://test.example.com';
    LAgent.XTitle := 'MCPAgentTest';

    LMessages := TJSONArray.Create;
    try
      LUserMsg := TJSONObject.Create;
      LUserMsg.AddPair('role', 'user');
      LUserMsg.AddPair('content', 'Reverse "hello"');
      LMessages.AddElement(LUserMsg);

      LResult := LAgent.Run(LMessages);

      if LResult.Content = 'reversed: olleh' then
        AR.Ok('agent loop produced final content from LLM')
      else
        AR.Fail('final content',
          Format('expected "reversed: olleh", got "%s"', [LResult.Content]));

      if LResult.ToolCallCount = 1 then
        AR.Ok('exactly one tool call dispatched')
      else
        AR.Fail('tool call count',
          Format('expected 1, got %d', [LResult.ToolCallCount]));

      // 2 LLM round-trips: turn 1 (tool_call), turn 2 (final).
      // Each fake LLM response advertises 50/20/70 → totals 100/40/140.
      if (LResult.PromptTokens = 100) and (LResult.CompletionTokens = 40)
         and (LResult.TotalTokens = 140) then
        AR.Ok('token accounting summed across turns (100+40=140)')
      else
        AR.Fail('token accounting',
          Format('got prompt=%d completion=%d total=%d (expected 100/40/140)',
            [LResult.PromptTokens, LResult.CompletionTokens, LResult.TotalTokens]));

      if G_LastSeenSystem = 'You are a helpful test agent.' then
        AR.Ok('SystemPrompt prepended as role:"system" first message')
      else
        AR.Fail('system prompt',
          Format('LLM saw "%s" as system', [G_LastSeenSystem]));

      if G_LastReferer = 'https://test.example.com' then
        AR.Ok('HTTPReferer header emitted')
      else
        AR.Fail('HTTPReferer',
          Format('expected https://test.example.com, got "%s"', [G_LastReferer]));

      if G_LastXTitle = 'MCPAgentTest' then
        AR.Ok('X-Title header emitted')
      else
        AR.Fail('X-Title',
          Format('expected MCPAgentTest, got "%s"', [G_LastXTitle]));
    finally
      LMessages.Free;
    end;
  except
    on E: Exception do
      AR.Fail('Run', E.ClassName + ': ' + E.Message);
  end;
  LAgent.Free;
end;

procedure TestMaxTurnsSafety(const AMCPURL: string; ALLMPort: Integer; AR: TTestRunner);
var
  LAgent: TMCPOpenAIAgent;
  LMessages: TJSONArray;
  LUserMsg: TJSONObject;
  LResult: TMCPAgentResult;
begin
  AR.Section('Max turns safety net');
  G_Mode := tmAlwaysToolCall;
  G_RequestCount := 0;

  LAgent := TMCPOpenAIAgent.Create(
    AMCPURL,
    'fake-api-key',
    'fake-model',
    Format('http://127.0.0.1:%d/v1', [ALLMPort]));
  try
    LAgent.MaxTurns := 3;

    LMessages := TJSONArray.Create;
    try
      LUserMsg := TJSONObject.Create;
      LUserMsg.AddPair('role', 'user');
      LUserMsg.AddPair('content', 'Loop forever');
      LMessages.AddElement(LUserMsg);

      LResult := LAgent.Run(LMessages);

      if Pos('max turns', LowerCase(LResult.Content)) > 0 then
        AR.Ok('agent terminated with max-turns notice')
      else
        AR.Fail('max-turns content',
          Format('expected "max turns" notice, got "%s"', [LResult.Content]));

      // MaxTurns=3 → exactly 3 LLM calls, exactly 3 tool dispatches.
      if LResult.ToolCallCount = 3 then
        AR.Ok('tool dispatched MaxTurns times before bailing out')
      else
        AR.Fail('tool dispatch count under max turns',
          Format('expected 3, got %d', [LResult.ToolCallCount]));
    finally
      LMessages.Free;
    end;
  except
    on E: Exception do
      AR.Fail('Run (max turns)', E.ClassName + ': ' + E.Message);
  end;
  LAgent.Free;
end;

// ──────────────────────────────────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────────────────────────────────

var
  LMCPURL: string;
  LLLMPort: Integer;
  LFakeLLM: IMVCServer;
  LR: TTestRunner;
  LSuccess: Boolean;
begin
  ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;
  LMCPURL := ParseStringArg('mcp-url', 'http://localhost:8080/mcp');
  LLLMPort := ParseIntArg('llm-port', 9091);

  WriteLn('TMCPOpenAIAgent compliance test');
  WriteLn('MCP server : ', LMCPURL);
  WriteLn('Fake LLM   : http://127.0.0.1:', LLLMPort, '/v1/chat/completions');
  WriteLn(StringOfChar('=', 60));

  G_RequestLock := TCriticalSection.Create;
  LR := TTestRunner.Create;
  try
    try
      LFakeLLM := StartFakeLLM(LLLMPort);
      try
        TestSingleToolCall(LMCPURL, LLLMPort, LR);
        TestMaxTurnsSafety(LMCPURL, LLLMPort, LR);
      finally
        LFakeLLM.Stop;
        LFakeLLM := nil;
        FreeAndNil(G_FakeLLMEngine);
      end;
    except
      on E: Exception do
      begin
        WriteLn('UNEXPECTED EXCEPTION: ', E.ClassName, ': ', E.Message);
        LR.Fail('top-level', E.Message);
      end;
    end;

    LSuccess := LR.Summary;
    if LSuccess then ExitCode := 0 else ExitCode := 1;
  finally
    LR.Free;
    G_RequestLock.Free;
  end;
end.
