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

// One SSE event: a data field closed by the blank line that dispatches it.
function SSEEvent(const AData: string): string;
begin
  Result := 'data: ' + AData + sLineBreak + sLineBreak;
end;

// Canned SSE bodies. The tool-call arguments are deliberately cut in two so
// the wire test exercises fragment reassembly and not just the happy path.
function SSEToolCallTurn(const AToolCallId: string): string;
begin
  Result :=
    SSEEvent('{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":' +
      '[{"index":0,"id":"' + AToolCallId + '","type":"function","function":' +
      '{"name":"reverse_string","arguments":"{\"Value\":"}}]}}]}') +
    SSEEvent('{"choices":[{"index":0,"delta":{"tool_calls":' +
      '[{"index":0,"function":{"arguments":"\"hello\"}"}}]}}]}') +
    SSEEvent('{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}') +
    SSEEvent('{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":20,' +
      '"total_tokens":70}}') +
    SSEEvent('[DONE]');
end;

function SSEFinalTurn: string;
begin
  Result :=
    SSEEvent('{"choices":[{"index":0,"delta":{"role":"assistant",' +
      '"content":"reversed: "}}]}') +
    SSEEvent('{"choices":[{"index":0,"delta":{"content":"olleh"}}]}') +
    SSEEvent('{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}') +
    SSEEvent('{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":20,' +
      '"total_tokens":70}}') +
    SSEEvent('[DONE]');
end;

procedure TFakeLLMController.ChatCompletions;
var
  LBody: string;
  LReq, LMsg, LResp, LChoice, LMessage, LUsage: TJSONObject;
  LMessages, LChoices, LToolCalls: TJSONArray;
  LRoleVal, LStreamVal: TJSONValue;
  LIsToolFollowUp, LWantsStream: Boolean;
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
  LWantsStream := False;
  G_LastSeenSystem := '';
  LReq := TJSONObject.ParseJSONValue(LBody) as TJSONObject;
  try
    if Assigned(LReq) then
    begin
      LStreamVal := LReq.FindValue('stream');
      LWantsStream := Assigned(LStreamVal) and (LStreamVal is TJSONBool)
                      and TJSONBool(LStreamVal).AsBoolean;
    end;
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

  // Streamed answer: same scenario, event-stream wire format.
  if LWantsStream then
  begin
    ContentType := 'text/event-stream';
    if (G_Mode = tmDispatchOnce) and LIsToolFollowUp then
      Render(SSEFinalTurn)
    else
      Render(SSEToolCallTurn('call_fake_' + IntToStr(G_RequestCount)));
    Exit;
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
// SSE accumulator — parser tests, no server and no LLM involved.
//
// This is where the chunk boundaries get nasty on purpose: a real provider
// cuts the stream wherever the socket happens to fill up, so the parser is
// fed the same bodies sliced in the places most likely to break it.
// ──────────────────────────────────────────────────────────────────────────

// Feeds AText as two chunks split at byte offset ASplitAt.
procedure FeedSplitAt(AAcc: TMCPSSEAccumulator; const AText: string; ASplitAt: Integer);
var
  LAll: TBytes;
begin
  LAll := TEncoding.UTF8.GetBytes(AText);
  AAcc.Feed(Copy(LAll, 0, ASplitAt));
  AAcc.Feed(Copy(LAll, ASplitAt, Length(LAll) - ASplitAt));
end;

// Byte offset just after the first lead byte of a multi-byte character:
// splitting there leaves half a character in the buffer.
function OffsetInsideMultiByteChar(const AText: string): Integer;
var
  LAll: TBytes;
  I: Integer;
begin
  LAll := TEncoding.UTF8.GetBytes(AText);
  for I := 0 to Length(LAll) - 1 do
    if LAll[I] >= $C2 then
      Exit(I + 1);
  Result := Length(LAll) div 2;
end;

function MessageOf(AResponse: TJSONObject): TJSONObject;
begin
  Result := (AResponse.GetValue('choices') as TJSONArray)
              .Items[0] as TJSONObject;
  Result := Result.GetValue('message') as TJSONObject;
end;

function FinishReasonOf(AResponse: TJSONObject): string;
begin
  Result := ((AResponse.GetValue('choices') as TJSONArray)
              .Items[0] as TJSONObject).GetValue<string>('finish_reason');
end;

procedure TestSSEContentSplitAcrossChunks(AR: TTestRunner);
var
  LAcc: TMCPSSEAccumulator;
  LResp: TJSONObject;
  LDeltas: TStringList;
  LExpected, LSSE: string;
begin
  AR.Section('SSE: text deltas, chunk split inside a UTF-8 character');

  // Built from code points so the test does not depend on the encoding of
  // this source file.
  LExpected := 'Perch' + #$00E8 + ' s' + #$00EC;
  LSSE :=
    SSEEvent('{"choices":[{"delta":{"content":"Perch"}}]}') +
    SSEEvent('{"choices":[{"delta":{"content":"' + #$00E8 + ' s' + #$00EC + '"}}]}') +
    SSEEvent('{"choices":[{"delta":{},"finish_reason":"stop"}]}') +
    SSEEvent('[DONE]');

  LDeltas := TStringList.Create;
  try
    LAcc := TMCPSSEAccumulator.Create(
      procedure(const ADelta: string)
      begin
        LDeltas.Add(ADelta);
      end);
    try
      FeedSplitAt(LAcc, LSSE, OffsetInsideMultiByteChar(LSSE));
      LAcc.Flush;

      LResp := LAcc.BuildResponse;
      try
        if MessageOf(LResp).GetValue<string>('content') = LExpected then
          AR.Ok('content reassembled across a split multi-byte character')
        else
          AR.Fail('content reassembly',
            Format('expected "%s", got "%s"',
              [LExpected, MessageOf(LResp).GetValue<string>('content')]));

        if FinishReasonOf(LResp) = 'stop' then
          AR.Ok('finish_reason carried over from the delta chunk')
        else
          AR.Fail('finish_reason', 'expected stop, got ' + FinishReasonOf(LResp));
      finally
        LResp.Free;
      end;

      if (LDeltas.Count = 2) and (LDeltas[0] = 'Perch')
         and (LDeltas[1] = #$00E8 + ' s' + #$00EC) then
        AR.Ok('OnContentDelta fired once per chunk, in order')
      else
        AR.Fail('delta callbacks',
          Format('got %d deltas: %s', [LDeltas.Count, LDeltas.CommaText]));

      if LAcc.Done then
        AR.Ok('[DONE] sentinel recognised')
      else
        AR.Fail('[DONE]', 'stream not marked as done');
    finally
      LAcc.Free;
    end;
  finally
    LDeltas.Free;
  end;
end;

procedure TestSSEToolCallFragments(AR: TTestRunner);
var
  LAcc: TMCPSSEAccumulator;
  LResp: TJSONObject;
  LToolCalls: TJSONArray;
  LCall, LFunc: TJSONObject;
  LSSE: string;
begin
  AR.Section('SSE: a single tool call split across chunks');

  // id and name only in the first fragment, arguments cut mid-JSON.
  LSSE :=
    SSEEvent('{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",' +
      '"type":"function","function":{"name":"reverse_string",' +
      '"arguments":"{\"Val"}}]}}]}') +
    SSEEvent('{"choices":[{"delta":{"tool_calls":[{"index":0,' +
      '"function":{"arguments":"ue\":\"hel"}}]}}]}') +
    SSEEvent('{"choices":[{"delta":{"tool_calls":[{"index":0,' +
      '"function":{"arguments":"lo\"}"}}]}}]}') +
    SSEEvent('{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}') +
    SSEEvent('[DONE]');

  LAcc := TMCPSSEAccumulator.Create;
  try
    LAcc.FeedText(LSSE);
    LAcc.Flush;

    LResp := LAcc.BuildResponse;
    try
      LToolCalls := MessageOf(LResp).GetValue('tool_calls') as TJSONArray;
      if LToolCalls.Count = 1 then
        AR.Ok('three fragments collapsed into one tool call')
      else
        AR.Fail('tool call count', Format('expected 1, got %d', [LToolCalls.Count]));

      LCall := LToolCalls.Items[0] as TJSONObject;
      LFunc := LCall.GetValue('function') as TJSONObject;

      if (LCall.GetValue<string>('id') = 'call_1')
         and (LFunc.GetValue<string>('name') = 'reverse_string') then
        AR.Ok('id and name kept from the first fragment')
      else
        AR.Fail('id/name',
          Format('got id="%s" name="%s"',
            [LCall.GetValue<string>('id'), LFunc.GetValue<string>('name')]));

      if LFunc.GetValue<string>('arguments') = '{"Value":"hello"}' then
        AR.Ok('arguments concatenated back into valid JSON')
      else
        AR.Fail('arguments reassembly',
          Format('expected {"Value":"hello"}, got %s',
            [LFunc.GetValue<string>('arguments')]));

      if FinishReasonOf(LResp) = 'tool_calls' then
        AR.Ok('finish_reason tool_calls preserved')
      else
        AR.Fail('finish_reason', 'got ' + FinishReasonOf(LResp));

      if MessageOf(LResp).GetValue('content') is TJSONNull then
        AR.Ok('content null when the turn only asked for tools')
      else
        AR.Fail('content', 'expected null content on a tool-call turn');
    finally
      LResp.Free;
    end;
  finally
    LAcc.Free;
  end;
end;

procedure TestSSEParallelToolCalls(AR: TTestRunner);
var
  LAcc: TMCPSSEAccumulator;
  LResp: TJSONObject;
  LToolCalls: TJSONArray;
  LFirst, LSecond: TJSONObject;
  LSSE: string;
begin
  AR.Section('SSE: two parallel tool calls, fragments interleaved');

  // index 1 opens before index 0 is finished, and the array arrives out of
  // order — the reassembled tool_calls must still be ordered by index.
  LSSE :=
    SSEEvent('{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a",' +
      '"function":{"name":"alpha","arguments":"{\"a\":"}}]}}]}') +
    SSEEvent('{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b",' +
      '"function":{"name":"beta","arguments":"{\"b\":"}}]}}]}') +
    SSEEvent('{"choices":[{"delta":{"tool_calls":[{"index":1,' +
      '"function":{"arguments":"2}"}}]}}]}') +
    SSEEvent('{"choices":[{"delta":{"tool_calls":[{"index":0,' +
      '"function":{"arguments":"1}"}}]}}]}') +
    SSEEvent('{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}') +
    SSEEvent('[DONE]');

  LAcc := TMCPSSEAccumulator.Create;
  try
    LAcc.FeedText(LSSE);
    LAcc.Flush;

    LResp := LAcc.BuildResponse;
    try
      LToolCalls := MessageOf(LResp).GetValue('tool_calls') as TJSONArray;
      if LToolCalls.Count = 2 then
        AR.Ok('both tool calls reassembled')
      else
        AR.Fail('parallel tool call count',
          Format('expected 2, got %d', [LToolCalls.Count]));

      LFirst  := LToolCalls.Items[0] as TJSONObject;
      LSecond := LToolCalls.Items[1] as TJSONObject;

      if (LFirst.GetValue<string>('id') = 'call_a')
         and (LSecond.GetValue<string>('id') = 'call_b') then
        AR.Ok('emitted in index order despite interleaved fragments')
      else
        AR.Fail('tool call order',
          Format('got %s then %s',
            [LFirst.GetValue<string>('id'), LSecond.GetValue<string>('id')]));

      if ((LFirst.GetValue('function') as TJSONObject).GetValue<string>('arguments') = '{"a":1}')
         and ((LSecond.GetValue('function') as TJSONObject).GetValue<string>('arguments') = '{"b":2}') then
        AR.Ok('arguments kept separate per index')
      else
        AR.Fail('per-index arguments', 'fragments leaked between tool calls');
    finally
      LResp.Free;
    end;
  finally
    LAcc.Free;
  end;
end;

procedure TestSSENoiseUsageAndFlush(AR: TTestRunner);
var
  LAcc: TMCPSSEAccumulator;
  LResp: TJSONObject;
  LUsage: TJSONObject;
  LSSE: string;
begin
  AR.Section('SSE: comments, usage-only chunk, missing final newline');

  // Note the absent trailing newline after [DONE]: only Flush can see it.
  // The `event:` field is there to prove a named event does not derail the
  // data payload that follows it.
  LSSE :=
    ': OPENROUTER PROCESSING' + sLineBreak +
    sLineBreak +
    SSEEvent('{"choices":[{"delta":{"content":"ok"}}]}') +
    'event: ping' + sLineBreak +
    'data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":22}}' + sLineBreak +
    sLineBreak +
    'data: [DONE]';

  LAcc := TMCPSSEAccumulator.Create;
  try
    LAcc.FeedText(LSSE);

    if not LAcc.Done then
      AR.Ok('unterminated last line held back until Flush')
    else
      AR.Fail('premature parse', 'line consumed before its terminator arrived');

    LAcc.Flush;

    if LAcc.Done then
      AR.Ok('Flush parsed the unterminated [DONE]')
    else
      AR.Fail('flush', 'trailing line lost');

    LResp := LAcc.BuildResponse;
    try
      if MessageOf(LResp).GetValue<string>('content') = 'ok' then
        AR.Ok('comment and event lines ignored')
      else
        AR.Fail('noise handling',
          'got ' + MessageOf(LResp).GetValue<string>('content'));

      LUsage := LResp.GetValue('usage') as TJSONObject;
      if (LUsage.GetValue<Integer>('prompt_tokens') = 11)
         and (LUsage.GetValue<Integer>('completion_tokens') = 22) then
        AR.Ok('usage read from the choices-less final chunk')
      else
        AR.Fail('usage', 'token totals not picked up');
    finally
      LResp.Free;
    end;
  finally
    LAcc.Free;
  end;
end;

procedure TestSSENonStreamBody(AR: TTestRunner);
var
  LAcc: TMCPSSEAccumulator;
begin
  AR.Section('SSE: body that is not an event stream');

  LAcc := TMCPSSEAccumulator.Create;
  try
    LAcc.FeedText('{"error":{"message":"invalid api key"}}');
    LAcc.Flush;

    if LAcc.IsEmpty then
      AR.Ok('plain JSON body parsed as empty, not as a silent "stop"')
    else
      AR.Fail('IsEmpty', 'a non-SSE body was mistaken for a stream');

    if Pos('invalid api key', LAcc.HeadText) > 0 then
      AR.Ok('body kept for the error message')
    else
      AR.Fail('HeadText', 'got "' + LAcc.HeadText + '"');
  finally
    LAcc.Free;
  end;
end;

procedure TestStreamingSingleToolCall(const AMCPURL: string; ALLMPort: Integer;
  AR: TTestRunner);
var
  LAgent: TMCPOpenAIAgent;
  LMessages: TJSONArray;
  LUserMsg: TJSONObject;
  LResult: TMCPAgentResult;
  LDeltas: TStringList;
begin
  AR.Section('Streaming end to end (agent + SSE fake LLM)');
  G_Mode := tmDispatchOnce;
  G_RequestCount := 0;

  LDeltas := TStringList.Create;
  LAgent := TMCPOpenAIAgent.Create(
    AMCPURL,
    'fake-api-key',
    'fake-model',
    Format('http://127.0.0.1:%d/v1', [ALLMPort]));
  try
    LAgent.MaxTurns := 5;
    LAgent.Streaming := True;
    LAgent.OnContentDelta :=
      procedure(const ADelta: string)
      begin
        LDeltas.Add(ADelta);
      end;

    LMessages := TJSONArray.Create;
    try
      LUserMsg := TJSONObject.Create;
      LUserMsg.AddPair('role', 'user');
      LUserMsg.AddPair('content', 'Reverse "hello"');
      LMessages.AddElement(LUserMsg);

      LResult := LAgent.Run(LMessages);

      // Same expectations as the buffered run: streaming must not change
      // the outcome, only when the caller learns about it.
      if LResult.Content = 'reversed: olleh' then
        AR.Ok('streamed run produced the same final content')
      else
        AR.Fail('streamed final content',
          Format('expected "reversed: olleh", got "%s"', [LResult.Content]));

      if LResult.ToolCallCount = 1 then
        AR.Ok('tool call dispatched from reassembled fragments')
      else
        AR.Fail('streamed tool call count',
          Format('expected 1, got %d', [LResult.ToolCallCount]));

      if (LResult.PromptTokens = 100) and (LResult.CompletionTokens = 40)
         and (LResult.TotalTokens = 140) then
        AR.Ok('stream_options usage chunk accounted across turns')
      else
        AR.Fail('streamed token accounting',
          Format('got prompt=%d completion=%d total=%d (expected 100/40/140)',
            [LResult.PromptTokens, LResult.CompletionTokens, LResult.TotalTokens]));

      if (LDeltas.Count = 2) and (LDeltas[0] = 'reversed: ')
         and (LDeltas[1] = 'olleh') then
        AR.Ok('OnContentDelta delivered the answer in fragments')
      else
        AR.Fail('streamed deltas',
          Format('got %d deltas: %s', [LDeltas.Count, LDeltas.CommaText]));
    finally
      LMessages.Free;
    end;
  except
    on E: Exception do
      AR.Fail('Run (streaming)', E.ClassName + ': ' + E.Message);
  end;
  LAgent.Free;
  LDeltas.Free;
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
      // Parser tests need neither the MCP server nor the fake LLM.
      TestSSEContentSplitAcrossChunks(LR);
      TestSSEToolCallFragments(LR);
      TestSSEParallelToolCalls(LR);
      TestSSENoiseUsageAndFlush(LR);
      TestSSENonStreamBody(LR);

      LFakeLLM := StartFakeLLM(LLLMPort);
      try
        TestSingleToolCall(LMCPURL, LLLMPort, LR);
        TestMaxTurnsSafety(LMCPURL, LLLMPort, LR);
        TestStreamingSingleToolCall(LMCPURL, LLLMPort, LR);
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
