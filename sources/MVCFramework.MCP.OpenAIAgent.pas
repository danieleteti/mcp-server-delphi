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

(* ============================================================================
  TMCPOpenAIAgent — Generic agent loop wiring an OpenAI-compatible LLM with
  an MCP server.

  -- Architecture --

      Caller (UI / batch / service / ...)
            |
            v
      TMCPOpenAIAgent.Run(messages: TJSONArray) : TMCPAgentResult
            |
            +───── POST  <BaseURL>/chat/completions
            |      (LLM in OpenAI chat-completions wire format)
            |
            +───── POST  <MCPURL>            (TMCPClient)
                   (MCP server: tools / resources / prompts)

  Despite the "OpenAI" in the name, this works against ANY service that
  speaks the OpenAI chat-completions wire format: api.openai.com,
  api.anthropic.com (via OpenAI-compat endpoint), OpenRouter, Together,
  Groq, Ollama (`/v1`), llama.cpp `--api`, vLLM, etc. The class is named
  for the WIRE FORMAT, not the vendor.

  Sister classes targeting other wire formats (Anthropic Messages,
  Google Gemini, AWS Bedrock) are not provided here — when needed they
  should derive their own from a common abstract base.

  -- Loop semantics --

  An "agent" is just a loop:

    1. Build the message list: [system, user, ...]
    2. Call the LLM with (messages, tools)
    3. The LLM responds:
         finish_reason = "stop"        -> we have the final answer, exit
         finish_reason = "tool_calls"  -> the LLM wants to invoke tools
    4. For each tool call:
         a. Execute the tool via the MCP server
         b. Append a {role:"tool", tool_call_id, content} message
    5. Go back to step 2

  MaxTurns is a safety net: a buggy or recursive tool plan could otherwise
  burn the entire context budget.

  -- MCP <-> OpenAI tool format bridge --

  MCP describes a tool with:                 OpenAI wants:
    name / description / inputSchema           type="function", function=
                                                 (name, description, parameters)

  inputSchema and parameters are both JSON Schema, so the bridge is a
  shallow rename + clone (see ToolToOpenAI).

  -- Token usage --

  Each turn the LLM returns prompt_tokens / completion_tokens in `usage`.
  The agent accumulates them and exposes the totals on TMCPAgentResult so
  callers can show running cost / watch for budget exhaustion.

  -- JSON ownership --

  Same convention as TMCPClient: methods that take a TJSONObject /
  TJSONArray CONSUME it; methods that return one TRANSFER ownership to
  the caller. AMessages passed to Run() is NOT consumed — Run() clones
  what it needs internally.
  ============================================================================ *)

unit MVCFramework.MCP.OpenAIAgent;

interface

uses
  System.Classes,
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.URLClient,
  MVCFramework.MCP.Client;

type
  // Structured result of one full agent run.
  TMCPAgentResult = record
    Content: string;            // final text from the assistant
    PromptTokens: Integer;      // sum across all turns
    CompletionTokens: Integer;  // sum across all turns
    TotalTokens: Integer;       // = Prompt + Completion (set when Run exits)
    ToolCallCount: Integer;     // total MCP tool calls executed during the run
  end;

  TMCPOpenAIAgent = class
  private
    FAPIKey: string;
    FBaseURL: string;
    FModel: string;
    FMCPURL: string;
    FMaxTurns: Integer;
    FSystemPrompt: string;
    FHTTPReferer: string;
    FXTitle: string;
    FResponseTimeoutMs: Integer;
    FConnectionTimeoutMs: Integer;
    FHTTP: THTTPClient;

    // Builds the chat/completions payload, posts it, and returns the parsed
    // response. Ownership of the result is transferred to the caller.
    function CallLLM(AMessages, ATools: TJSONArray): TJSONObject;

    // Bridges a single MCP tool descriptor to OpenAI function-calling format.
    // Returns a fresh TJSONObject owned by the caller.
    function ToolToOpenAI(ATool: TJSONObject): TJSONObject;

    // Executes every tool call requested by the LLM in a single turn and
    // appends their results to AWorking as role:"tool" messages.
    procedure DispatchToolCalls(AToolCalls: TJSONArray;
      AMCP: TMCPClient; AWorking: TJSONArray; var AStats: TMCPAgentResult);
  public
    // Constructor takes the four essentials. Use properties for the rest.
    // ABaseURL defaults to OpenAI's public endpoint; override for OpenRouter,
    // Anthropic-compat, Ollama, etc.
    constructor Create(const AMCPURL, AAPIKey, AModel: string;
      const ABaseURL: string = 'https://api.openai.com/v1');
    destructor Destroy; override;

    // Runs the loop with the conversation history AMessages (typically a
    // single role:"user" message). AMessages is NOT consumed — the agent
    // clones what it needs.
    function Run(AMessages: TJSONArray): TMCPAgentResult;

    // ---- Configuration ------------------------------------------------------

    property APIKey: string read FAPIKey write FAPIKey;
    property BaseURL: string read FBaseURL write FBaseURL;
    property Model: string read FModel write FModel;
    property MCPURL: string read FMCPURL write FMCPURL;

    // Hard cap on the number of LLM round-trips. Defaults to 25. Set lower
    // for predictable cost ceilings; set higher for long multi-step plans.
    property MaxTurns: Integer read FMaxTurns write FMaxTurns;

    // Prepended as a {role:"system", content: ...} message at the head of
    // every Run. When empty (default) no system message is added — caller
    // is expected to put it into AMessages itself if desired.
    property SystemPrompt: string read FSystemPrompt write FSystemPrompt;

    // Optional HTTP headers used by some OpenAI-compatible providers
    // (notably OpenRouter) for analytics/attribution. When empty (default)
    // the headers are omitted.
    property HTTPReferer: string read FHTTPReferer write FHTTPReferer;
    property XTitle: string read FXTitle write FXTitle;

    // HTTP timeouts (ms). Defaults: response 300000 (5 min), connection 10000.
    property ResponseTimeoutMs: Integer read FResponseTimeoutMs write FResponseTimeoutMs;
    property ConnectionTimeoutMs: Integer read FConnectionTimeoutMs write FConnectionTimeoutMs;
  end;

implementation

// ──────────────────────────────────────────────────────────────────────────
// Construction / destruction
// ──────────────────────────────────────────────────────────────────────────

constructor TMCPOpenAIAgent.Create(const AMCPURL, AAPIKey, AModel: string;
  const ABaseURL: string);
begin
  inherited Create;
  FMCPURL              := AMCPURL;
  FAPIKey              := AAPIKey;
  FModel               := AModel;
  FBaseURL             := ABaseURL;
  FMaxTurns            := 25;
  FSystemPrompt        := '';
  FHTTPReferer         := '';
  FXTitle              := '';
  FResponseTimeoutMs   := 300000;
  FConnectionTimeoutMs := 10000;

  FHTTP := THTTPClient.Create;
  FHTTP.ResponseTimeout   := FResponseTimeoutMs;
  FHTTP.ConnectionTimeout := FConnectionTimeoutMs;
end;

destructor TMCPOpenAIAgent.Destroy;
begin
  FHTTP.Free;
  inherited;
end;

// ──────────────────────────────────────────────────────────────────────────
// MCP -> OpenAI tool format bridge
//
// MCP:                          OpenAI:
//   name: "..."                    type: "function"
//   description: "..."             function:
//   inputSchema: <JSON-Schema>       name: "..."
//                                    description: "..."
//                                    parameters: <JSON-Schema>   <-- same payload
//
// Both ends use JSON Schema — copying the schema is enough.
// ──────────────────────────────────────────────────────────────────────────

function TMCPOpenAIAgent.ToolToOpenAI(ATool: TJSONObject): TJSONObject;
var
  LName, LDesc: string;
  LSchemaValue: TJSONValue;
  LSchema, LFunc: TJSONObject;
  LDescVal: TJSONValue;
begin
  // "name" is required in the MCP shape, but be defensive: with FindValue we
  // tolerate malformed tools and let the LLM reject them later.
  LName := '';
  if Assigned(ATool.FindValue('name')) then
    LName := ATool.GetValue<string>('name');

  LDesc := '';
  LDescVal := ATool.FindValue('description');
  if Assigned(LDescVal) and (LDescVal is TJSONString) then
    LDesc := TJSONString(LDescVal).Value;

  // The schema is already JSON Schema in both formats — clone it. When
  // missing (parameter-less tool) emit an empty-object schema so the LLM
  // is told the function takes nothing.
  LSchemaValue := ATool.FindValue('inputSchema');
  if Assigned(LSchemaValue) and (LSchemaValue is TJSONObject) then
    LSchema := TJSONObject(LSchemaValue).Clone as TJSONObject
  else
  begin
    LSchema := TJSONObject.Create;
    LSchema.AddPair('type', 'object');
    LSchema.AddPair('properties', TJSONObject.Create);
  end;

  LFunc := TJSONObject.Create;
  LFunc.AddPair('name',        LName);
  LFunc.AddPair('description', LDesc);
  LFunc.AddPair('parameters',  LSchema);

  Result := TJSONObject.Create;
  Result.AddPair('type',     'function');
  Result.AddPair('function', LFunc);
end;

// ──────────────────────────────────────────────────────────────────────────
// POST /chat/completions
//
// Authorization Bearer carries the API key. HTTPReferer / XTitle are
// emitted only when non-empty (OpenRouter analytics).
// ──────────────────────────────────────────────────────────────────────────

function TMCPOpenAIAgent.CallLLM(AMessages, ATools: TJSONArray): TJSONObject;
var
  LBody: TJSONObject;
  LStream: TStringStream;
  LResp: IHTTPResponse;
  LHeaders: TNetHeaders;
  LValue: TJSONValue;
  LURL: string;
begin
  // We clone messages and tools: AddPair transfers ownership to the body,
  // and freeing LBody at the end would otherwise destroy the caller's
  // structures. Cloning keeps the ownership story trivial.
  LBody := TJSONObject.Create;
  try
    LBody.AddPair('model',    FModel);
    LBody.AddPair('messages', AMessages.Clone as TJSONArray);
    if Assigned(ATools) and (ATools.Count > 0) then
      LBody.AddPair('tools', ATools.Clone as TJSONArray);

    LHeaders := [
      TNameValuePair.Create('Authorization', 'Bearer ' + FAPIKey),
      TNameValuePair.Create('Content-Type',  'application/json')
    ];
    if FHTTPReferer <> '' then
      LHeaders := LHeaders + [TNameValuePair.Create('HTTP-Referer', FHTTPReferer)];
    if FXTitle <> '' then
      LHeaders := LHeaders + [TNameValuePair.Create('X-Title', FXTitle)];

    LStream := TStringStream.Create(LBody.ToJSON, TEncoding.UTF8);
    try
      // Build the full URL, tolerating a trailing slash in the base URL —
      // some reverse proxies reject double slashes.
      LURL := FBaseURL;
      if (LURL <> '') and (LURL[Length(LURL)] = '/') then
        SetLength(LURL, Length(LURL) - 1);
      LURL := LURL + '/chat/completions';

      LResp := FHTTP.Post(LURL, LStream, nil, LHeaders);
    finally
      LStream.Free;
    end;
  finally
    LBody.Free;
  end;

  if (LResp.StatusCode < 200) or (LResp.StatusCode >= 300) then
    raise Exception.CreateFmt('LLM HTTP %d: %s',
      [LResp.StatusCode, Copy(LResp.ContentAsString, 1, 800)]);

  LValue := TJSONObject.ParseJSONValue(LResp.ContentAsString);
  if not (LValue is TJSONObject) then
  begin
    if Assigned(LValue) then
      LValue.Free;
    raise Exception.Create('LLM returned non-JSON response');
  end;
  Result := TJSONObject(LValue);
end;

// ──────────────────────────────────────────────────────────────────────────
// Tool calls dispatch
//
// OpenAI tool_call shape:
//   id = "call_abc123"            <-- bind to tool_call_id in the response
//   type = "function"
//   function:
//     name = "get_customer_detail"
//     arguments = '{"id": 42}'    <-- JSON STRING, not object!
//
// The tool result message must look like:
//   role = "tool"
//   tool_call_id = "call_abc123"
//   content = "<text>"
// ──────────────────────────────────────────────────────────────────────────

procedure TMCPOpenAIAgent.DispatchToolCalls(AToolCalls: TJSONArray;
  AMCP: TMCPClient; AWorking: TJSONArray; var AStats: TMCPAgentResult);
var
  I: Integer;
  LToolCallObj, LFunc, LToolMsg, LArgsObj: TJSONObject;
  LToolName, LArgsStr, LToolCallID, LResultText: string;
  LArgsValue: TJSONValue;
begin
  for I := 0 to AToolCalls.Count - 1 do
  begin
    LToolCallObj := AToolCalls.Items[I] as TJSONObject;
    LToolCallID  := LToolCallObj.GetValue<string>('id');
    LFunc        := LToolCallObj.GetValue<TJSONObject>('function');
    LToolName    := LFunc.GetValue<string>('name');

    // "arguments" is a JSON STRING (historical OpenAI quirk to avoid
    // malformed JSON inside the larger payload). Re-parse to get an object.
    LArgsStr := '{}';
    if Assigned(LFunc.FindValue('arguments')) then
      LArgsStr := LFunc.GetValue<string>('arguments');
    if Trim(LArgsStr) = '' then
      LArgsStr := '{}';

    Inc(AStats.ToolCallCount);

    // Catch ANY exception from the tool call and turn it into a textual
    // error message: the LLM reads it and decides how to react (retry with
    // different args, ask the user, give up). Letting an exception escape
    // would kill the loop and lose the conversation context.
    try
      LArgsValue := TJSONObject.ParseJSONValue(LArgsStr);
      if LArgsValue is TJSONObject then
        LArgsObj := TJSONObject(LArgsValue)
      else
      begin
        if Assigned(LArgsValue) then
          LArgsValue.Free;
        LArgsObj := TJSONObject.Create;
      end;
      // CallTool consumes LArgsObj — no explicit Free here.
      LResultText := AMCP.CallTool(LToolName, LArgsObj);
    except
      on E: Exception do
        LResultText := '[tool error: ' + E.Message + ']';
    end;

    // tool_call_id MUST match the id from the request — the LLM uses it to
    // reconcile which tool produced which output (especially when several
    // were dispatched in parallel in the same turn).
    LToolMsg := TJSONObject.Create;
    LToolMsg.AddPair('role',         'tool');
    LToolMsg.AddPair('tool_call_id', LToolCallID);
    LToolMsg.AddPair('content',      LResultText);
    AWorking.AddElement(LToolMsg);
  end;
end;

// ──────────────────────────────────────────────────────────────────────────
// Run: the main loop
//
// Memory strategy:
//   LToolsRaw -> LTools -> LWorking
// Three arrays that live for the duration of Run, each with its own
// try/finally so cleanup is guaranteed even if the LLM call throws.
// ──────────────────────────────────────────────────────────────────────────

function TMCPOpenAIAgent.Run(AMessages: TJSONArray): TMCPAgentResult;
var
  LMCP: TMCPClient;
  LWorking, LToolsRaw, LTools: TJSONArray;
  I, LTurn: Integer;
  LResp, LChoice, LMessage, LUsage, LSystemMsg, LAssistMsg: TJSONObject;
  LChoices, LToolCalls: TJSONArray;
  LFinishReason: string;
  LContentVal: TJSONValue;
  LUsageVal: TJSONValue;
  LPrompt, LCompletion: Integer;
begin
  // Local records are NOT zero-initialised in Delphi.
  Result.Content          := '';
  Result.PromptTokens     := 0;
  Result.CompletionTokens := 0;
  Result.TotalTokens      := 0;
  Result.ToolCallCount    := 0;

  // 1. MCP connection + handshake.
  LMCP := TMCPClient.Create(FMCPURL);
  try
    LMCP.Initialize;

    // 2. Discover tools and bridge them to OpenAI format.
    LToolsRaw := LMCP.ListTools;
    try
      LTools := TJSONArray.Create;
      try
        for I := 0 to LToolsRaw.Count - 1 do
          LTools.AddElement(ToolToOpenAI(LToolsRaw.Items[I] as TJSONObject));

        // 3. Build the working message history.
        // LWorking grows turn after turn: starts with optional system prompt
        // + caller messages, accumulates assistant + tool messages, ends
        // with the final assistant answer.
        LWorking := TJSONArray.Create;
        try
          if FSystemPrompt <> '' then
          begin
            LSystemMsg := TJSONObject.Create;
            LSystemMsg.AddPair('role',    'system');
            LSystemMsg.AddPair('content', FSystemPrompt);
            LWorking.AddElement(LSystemMsg);
          end;

          // Clone caller messages: LWorking owns its contents and we don't
          // want freeing it to destroy AMessages.
          for I := 0 to AMessages.Count - 1 do
          begin
            if AMessages.Items[I] is TJSONObject then
              LWorking.AddElement(TJSONObject(AMessages.Items[I]).Clone as TJSONObject);
          end;

          // 4. Loop up to MaxTurns.
          for LTurn := 1 to FMaxTurns do
          begin
            LResp := CallLLM(LWorking, LTools);
            try
              // 4a. Token accounting (best-effort — `usage` is optional).
              LUsageVal := LResp.FindValue('usage');
              if Assigned(LUsageVal) and (LUsageVal is TJSONObject) then
              begin
                LUsage := TJSONObject(LUsageVal);
                LPrompt     := 0;
                LCompletion := 0;
                if Assigned(LUsage.FindValue('prompt_tokens')) then
                  LPrompt := LUsage.GetValue<Integer>('prompt_tokens');
                if Assigned(LUsage.FindValue('completion_tokens')) then
                  LCompletion := LUsage.GetValue<Integer>('completion_tokens');
                Inc(Result.PromptTokens,     LPrompt);
                Inc(Result.CompletionTokens, LCompletion);
              end;

              // 4b. Extract the first choice. chat/completions is single-choice
              // by default (n=1). Missing choices means upstream error.
              LChoices := LResp.GetValue<TJSONArray>('choices');
              if (not Assigned(LChoices)) or (LChoices.Count = 0) then
                raise Exception.Create('LLM response missing "choices"');
              LChoice := LChoices.Items[0] as TJSONObject;

              LFinishReason := '';
              if Assigned(LChoice.FindValue('finish_reason')) then
                LFinishReason := LChoice.GetValue<string>('finish_reason');

              LMessage := LChoice.GetValue<TJSONObject>('message');

              LToolCalls := nil;
              if Assigned(LMessage.FindValue('tool_calls')) then
                LToolCalls := LMessage.GetValue('tool_calls') as TJSONArray;

              // 4c. Termination: finish_reason != "tool_calls" or empty
              // tool_calls means the LLM is done — extract content and exit.
              if (LFinishReason <> 'tool_calls')
                 or (not Assigned(LToolCalls))
                 or (LToolCalls.Count = 0) then
              begin
                LContentVal := LMessage.FindValue('content');
                if Assigned(LContentVal) and (LContentVal is TJSONString) then
                  Result.Content := TJSONString(LContentVal).Value;
                Result.TotalTokens := Result.PromptTokens + Result.CompletionTokens;
                Exit;
              end;

              // 4d. Continue: append the assistant message (containing the
              // tool_calls) BEFORE the tool results. The LLM needs the
              // assistant message in history to reconcile tool_call_ids on
              // the next turn.
              LAssistMsg := LMessage.Clone as TJSONObject;
              LWorking.AddElement(LAssistMsg);

              DispatchToolCalls(LToolCalls, LMCP, LWorking, Result);
            finally
              LResp.Free;
            end;
          end;

          // Exited by MaxTurns exhaustion.
          Result.Content := '(max turns reached - partial result above)';
          Result.TotalTokens := Result.PromptTokens + Result.CompletionTokens;
        finally
          LWorking.Free;
        end;
      finally
        LTools.Free;
      end;
    finally
      LToolsRaw.Free;
    end;
  finally
    LMCP.Free;
  end;
end;

end.
