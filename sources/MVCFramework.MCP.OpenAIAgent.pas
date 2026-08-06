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

  -- Streaming --

  Set Streaming := True and the agent asks the LLM for `stream: true`, then
  consumes the Server-Sent Events channel instead of a single JSON body.
  OnContentDelta fires for every text fragment as it arrives, so a UI can
  paint the answer while the model is still writing it.

  The loop itself is unchanged: TMCPSSEAccumulator reassembles the chunk
  deltas and synthesises the very same non-streaming envelope Run already
  knows how to read. The tricky part is not the text but the tool calls:

    data: {"choices":[{"delta":{"tool_calls":[
            {"index":0,"id":"call_1","function":{"name":"get_customer",
             "arguments":"{\"id\""}}]}}]}
    data: {"choices":[{"delta":{"tool_calls":[
            {"index":0,"function":{"arguments":":42}"}}]}}]}
    data: [DONE]

  `id` and `name` usually arrive only in the first fragment of a given
  index, while `arguments` is a JSON string sliced across an arbitrary
  number of chunks — cut anywhere, including in the middle of an escape
  sequence. Fragments are therefore keyed by `index` (several tool calls
  can interleave in the same turn) and concatenated verbatim; the result
  is parsed only once the stream is complete.

  Run stays synchronous: OnContentDelta is called on the calling thread,
  so a VCL/FMX caller runs Run in a worker thread and marshals the deltas
  itself.

  -- Token usage while streaming --

  A streamed response carries no `usage` object by default. When
  StreamUsage is True (the default) the agent adds
  `stream_options: {"include_usage": true}` to the request, and providers
  that honour it emit a final chunk with an empty `choices` array plus the
  usage totals. Providers that reject unknown fields need StreamUsage set
  to False, at the cost of losing token accounting for that run.

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
  System.Generics.Defaults,
  System.Net.HttpClient,
  System.Net.URLClient,
  MVCFramework.SSEClient,
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

  // Fired for every text fragment streamed back by the LLM, in arrival
  // order. Called on the thread running Run — a VCL/FMX caller marshals to
  // the UI thread itself (TThread.Queue).
  TMCPAgentDeltaProc = reference to procedure(const ADelta: string);

  // Reassembles an OpenAI-compatible SSE stream into the non-streaming
  // response envelope the agent loop already understands.
  //
  // Feed it raw bytes as they arrive (Feed), call Flush when the request
  // ends, then BuildResponse. Public because this is the part worth testing
  // on its own: every provider slices the stream differently, and a chunk
  // boundary can fall anywhere — inside a UTF-8 sequence, inside a JSON
  // string, between the two halves of a tool-call argument.
  //
  // The SSE grammar itself (fields, comments, CR/LF/CRLF framing, blank-line
  // dispatch) is DMVCFramework's TSSEClientParser. What is added on top is
  // the byte layer: chunks are decoded only up to their last complete line,
  // because decoding a raw chunk would mangle any multi-byte character
  // unlucky enough to straddle the boundary.
  TMCPSSEAccumulator = class
  private const
    // A server that never sends a newline would otherwise grow FPending
    // without bound. 8 MiB is far above any legitimate single SSE line.
    MAX_PENDING_BYTES = 8 * 1024 * 1024;
    // Kept only to build a useful message when the response turns out to
    // be an HTTP error body rather than an event stream.
    MAX_HEAD_BYTES = 2048;
  private type
    // One tool call under construction, keyed by its `index` in the stream.
    TToolCallFragment = record
      Index: Integer;
      Id: string;
      Name: string;
      Arguments: string;   // concatenated verbatim, parsed only at the end
    end;
  private
    FParser: TSSEClientParser;             // DMVCFramework's SSE grammar
    FPending: TBytes;                      // bytes not yet closed by a LF
    FHead: TBytes;                         // first bytes seen, for errors
    FContent: TStringBuilder;
    FFragments: TList<TToolCallFragment>;
    FFinishReason: string;
    FPromptTokens: Integer;
    FCompletionTokens: Integer;
    FHasUsage: Boolean;
    FDone: Boolean;
    FOnDelta: TMCPAgentDeltaProc;
    function FragmentIndexOf(AIndex: Integer): Integer;
    procedure ApplyChunk(AChunk: TJSONObject);
    procedure ApplyDelta(ADelta: TJSONObject);
    procedure ApplyToolCallDeltas(AToolCalls: TJSONArray);
    procedure ApplyUsage(AUsage: TJSONObject);
    procedure HandleEventData(const AData: string);
  public
    constructor Create(AOnDelta: TMCPAgentDeltaProc = nil);
    destructor Destroy; override;

    // Consume a chunk of the response body. Lines are decoded only once
    // complete, so a multi-byte character split across two chunks survives.
    procedure Feed(const ABytes: TBytes);
    // Convenience for tests and for feeding an already-decoded body.
    procedure FeedText(const AText: string);
    // Call when the connection closes: emits a trailing line that was not
    // terminated by a newline.
    procedure Flush;

    // The synthesised {choices:[{message:{...}}], usage:{...}} object.
    // Ownership goes to the caller.
    function BuildResponse: TJSONObject;
    // First bytes of the body as text, for error reporting.
    function HeadText: string;
    // True when no chunk was ever parsed: no text, no tool fragment, no
    // finish reason, no usage. Tells "the model said nothing" apart from
    // "this body was never an event stream".
    function IsEmpty: Boolean;

    // True once `data: [DONE]` has been seen.
    property Done: Boolean read FDone;
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
    FMCPClient: TMCPClientBase;
    FOwnsMCPClient: Boolean;
    FStreaming: Boolean;
    FStreamUsage: Boolean;
    FOnContentDelta: TMCPAgentDeltaProc;

    // Request shape, shared by the buffered and the streaming paths.
    function BuildRequestBody(AMessages, ATools: TJSONArray;
      AStreaming: Boolean): TJSONObject;
    function BuildHeaders(AStreaming: Boolean): TNetHeaders;
    function BuildURL: string;

    // Builds the chat/completions payload, posts it, and returns the parsed
    // response. Ownership of the result is transferred to the caller.
    function CallLLM(AMessages, ATools: TJSONArray): TJSONObject;

    // Same contract as CallLLM, but consumes an SSE stream and synthesises
    // the equivalent buffered envelope, so the loop cannot tell them apart.
    function CallLLMStreaming(AMessages, ATools: TJSONArray): TJSONObject;

    // Bridges a single MCP tool descriptor to OpenAI function-calling format.
    // Returns a fresh TJSONObject owned by the caller.
    function ToolToOpenAI(ATool: TJSONObject): TJSONObject;

    // Executes every tool call requested by the LLM in a single turn and
    // appends their results to AWorking as role:"tool" messages.
    procedure DispatchToolCalls(AToolCalls: TJSONArray;
      AMCP: TMCPClientBase; AWorking: TJSONArray; var AStats: TMCPAgentResult);
  public
    // Constructor takes the four essentials. Use properties for the rest.
    // ABaseURL defaults to OpenAI's public endpoint; override for OpenRouter,
    // Anthropic-compat, Ollama, etc. The default transport is HTTP — Run
    // creates a fresh TMCPClient(MCPURL) for every call. To use a different
    // transport (e.g. stdio), inject a pre-built client via SetMCPClient
    // BEFORE Run.
    constructor Create(const AMCPURL, AAPIKey, AModel: string;
      const ABaseURL: string = 'https://api.openai.com/v1');
    destructor Destroy; override;

    // Runs the loop with the conversation history AMessages (typically a
    // single role:"user" message). AMessages is NOT consumed — the agent
    // clones what it needs.
    function Run(AMessages: TJSONArray): TMCPAgentResult;

    // Inject an already-built client (e.g. a TMCPStdioClient that wraps a
    // child-process server) so Run uses it instead of creating a fresh
    // TMCPClient from MCPURL. When AOwns is True the agent will Free the
    // client on its own destruction; when False the caller stays in charge
    // of the lifecycle.
    procedure SetMCPClient(AClient: TMCPClientBase; AOwns: Boolean);

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

    // ---- Streaming ----------------------------------------------------------

    // Ask the LLM for `stream: true` and consume the SSE channel. Defaults
    // to False: the result of Run is identical either way, only the timing
    // of OnContentDelta changes.
    property Streaming: Boolean read FStreaming write FStreaming;

    // Called for every text fragment while streaming, on the calling
    // thread. Ignored when Streaming is False.
    property OnContentDelta: TMCPAgentDeltaProc read FOnContentDelta write FOnContentDelta;

    // Add `stream_options: {"include_usage": true}` so a streamed run still
    // reports token usage. Defaults to True. Set to False for providers
    // that reject the field (token counters then stay at zero).
    property StreamUsage: Boolean read FStreamUsage write FStreamUsage;
  end;

implementation

// ──────────────────────────────────────────────────────────────────────────
// TMCPSSEAccumulator
//
// Wire format (one event per blank-line-separated block, but OpenAI-compat
// providers only ever use the `data:` field, one JSON object per line):
//
//   : a comment, sent by some providers as a keep-alive
//   data: {"choices":[{"delta":{"content":"Hel"}}]}
//   data: {"choices":[{"delta":{"content":"lo"}}]}
//   data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
//   data: {"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":20}}
//   data: [DONE]
//
// Anything that is not a `data:` line is ignored, which covers comments,
// blank separators and the `event:` / `id:` / `retry:` fields nobody sends
// here.
// ──────────────────────────────────────────────────────────────────────────

constructor TMCPSSEAccumulator.Create(AOnDelta: TMCPAgentDeltaProc);
begin
  inherited Create;
  FContent   := TStringBuilder.Create;
  FFragments := TList<TToolCallFragment>.Create;
  FOnDelta   := AOnDelta;
  SetLength(FPending, 0);
  SetLength(FHead, 0);

  FParser := TSSEClientParser.Create;
  FParser.OnEvent :=
    procedure(const AId, AEvent, AData: string)
    begin
      // id/event are unused here: OpenAI-compatible providers only ever
      // send `data:` payloads.
      HandleEventData(AData);
    end;
end;

destructor TMCPSSEAccumulator.Destroy;
begin
  FParser.Free;
  FFragments.Free;
  FContent.Free;
  inherited;
end;

procedure TMCPSSEAccumulator.Feed(const ABytes: TBytes);
var
  LOld, I, LLastLF, LHeadRoom: Integer;
  LComplete: TBytes;
begin
  if Length(ABytes) = 0 then
    Exit;

  // Keep the opening bytes around: when the server answers with an HTTP
  // error the body is JSON, not an event stream, and this is all we have
  // left to put in the exception message.
  LHeadRoom := MAX_HEAD_BYTES - Length(FHead);
  if LHeadRoom > 0 then
  begin
    if LHeadRoom > Length(ABytes) then
      LHeadRoom := Length(ABytes);
    LOld := Length(FHead);
    SetLength(FHead, LOld + LHeadRoom);
    Move(ABytes[0], FHead[LOld], LHeadRoom);
  end;

  LOld := Length(FPending);
  if LOld + Length(ABytes) > MAX_PENDING_BYTES then
    raise Exception.Create(
      'SSE stream: no line terminator within ' +
      IntToStr(MAX_PENDING_BYTES) + ' bytes, aborting');
  SetLength(FPending, LOld + Length(ABytes));
  Move(ABytes[0], FPending[LOld], Length(ABytes));

  // Hand the parser everything up to the last complete line and keep the
  // rest for the next chunk. A line boundary is always a character
  // boundary, so decoding here can never cut a multi-byte sequence in half.
  LLastLF := -1;
  for I := Length(FPending) - 1 downto 0 do
    if FPending[I] = 10 then
    begin
      LLastLF := I;
      Break;
    end;

  if LLastLF >= 0 then
  begin
    LComplete := Copy(FPending, 0, LLastLF + 1);
    FPending := Copy(FPending, LLastLF + 1, Length(FPending) - LLastLF - 1);
    FParser.Feed(TEncoding.UTF8.GetString(LComplete));
  end;
end;

procedure TMCPSSEAccumulator.FeedText(const AText: string);
begin
  Feed(TEncoding.UTF8.GetBytes(AText));
end;

procedure TMCPSSEAccumulator.Flush;
var
  LTail: string;
begin
  // Two loose ends when the connection closes: a last line that never got
  // its newline, and a last event that never got its blank line. Feeding a
  // final LF pair closes both — the parser dispatches whatever it holds.
  if Length(FPending) > 0 then
  begin
    LTail := TEncoding.UTF8.GetString(FPending);
    SetLength(FPending, 0);
    FParser.Feed(LTail + #10);
  end;
  FParser.Feed(#10);
end;

procedure TMCPSSEAccumulator.HandleEventData(const AData: string);
var
  LPayload: string;
  LValue: TJSONValue;
begin
  LPayload := AData.Trim;
  if LPayload = '' then
    Exit;
  if LPayload = '[DONE]' then
  begin
    FDone := True;
    Exit;
  end;

  LValue := TJSONObject.ParseJSONValue(LPayload);
  if not Assigned(LValue) then
    Exit;   // a truncated or malformed chunk must not kill the whole run
  try
    if LValue is TJSONObject then
      ApplyChunk(TJSONObject(LValue));
  finally
    LValue.Free;
  end;
end;

procedure TMCPSSEAccumulator.ApplyChunk(AChunk: TJSONObject);
var
  LChoices: TJSONArray;
  LChoice: TJSONObject;
  LValue, LFinishVal: TJSONValue;
begin
  // The usage-only chunk carries an empty `choices`, so read usage first
  // and never assume a choice is there.
  LValue := AChunk.FindValue('usage');
  if Assigned(LValue) and (LValue is TJSONObject) then
    ApplyUsage(TJSONObject(LValue));

  LValue := AChunk.FindValue('choices');
  if not (LValue is TJSONArray) then
    Exit;
  LChoices := TJSONArray(LValue);
  if LChoices.Count = 0 then
    Exit;
  if not (LChoices.Items[0] is TJSONObject) then
    Exit;
  LChoice := TJSONObject(LChoices.Items[0]);

  LFinishVal := LChoice.FindValue('finish_reason');
  if Assigned(LFinishVal) and (LFinishVal is TJSONString) then
    FFinishReason := TJSONString(LFinishVal).Value;

  LValue := LChoice.FindValue('delta');
  if Assigned(LValue) and (LValue is TJSONObject) then
    ApplyDelta(TJSONObject(LValue));
end;

procedure TMCPSSEAccumulator.ApplyDelta(ADelta: TJSONObject);
var
  LValue: TJSONValue;
  LText: string;
begin
  // `content` is null in the chunks that carry tool calls.
  LValue := ADelta.FindValue('content');
  if Assigned(LValue) and (LValue is TJSONString) then
  begin
    LText := TJSONString(LValue).Value;
    if LText <> '' then
    begin
      FContent.Append(LText);
      if Assigned(FOnDelta) then
        FOnDelta(LText);
    end;
  end;

  LValue := ADelta.FindValue('tool_calls');
  if Assigned(LValue) and (LValue is TJSONArray) then
    ApplyToolCallDeltas(TJSONArray(LValue));
end;

function TMCPSSEAccumulator.FragmentIndexOf(AIndex: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to FFragments.Count - 1 do
    if FFragments[I].Index = AIndex then
      Exit(I);
  Result := -1;
end;

procedure TMCPSSEAccumulator.ApplyToolCallDeltas(AToolCalls: TJSONArray);
var
  I, LPos, LIndex: Integer;
  LItem, LFunc: TJSONObject;
  LValue: TJSONValue;
  LFrag: TToolCallFragment;
begin
  for I := 0 to AToolCalls.Count - 1 do
  begin
    if not (AToolCalls.Items[I] is TJSONObject) then
      Continue;
    LItem := TJSONObject(AToolCalls.Items[I]);

    // `index` identifies the tool call across chunks. Providers that emit a
    // single tool call sometimes omit it — treat that as index 0.
    LIndex := 0;
    LValue := LItem.FindValue('index');
    if Assigned(LValue) and (LValue is TJSONNumber) then
      LIndex := TJSONNumber(LValue).AsInt;

    LPos := FragmentIndexOf(LIndex);
    if LPos < 0 then
    begin
      LFrag.Index     := LIndex;
      LFrag.Id        := '';
      LFrag.Name      := '';
      LFrag.Arguments := '';
      FFragments.Add(LFrag);
      LPos := FFragments.Count - 1;
    end;
    LFrag := FFragments[LPos];

    // id and name normally arrive once, in the first fragment.
    LValue := LItem.FindValue('id');
    if Assigned(LValue) and (LValue is TJSONString)
       and (TJSONString(LValue).Value <> '') then
      LFrag.Id := TJSONString(LValue).Value;

    LValue := LItem.FindValue('function');
    if Assigned(LValue) and (LValue is TJSONObject) then
    begin
      LFunc := TJSONObject(LValue);

      LValue := LFunc.FindValue('name');
      if Assigned(LValue) and (LValue is TJSONString)
         and (TJSONString(LValue).Value <> '') then
        LFrag.Name := TJSONString(LValue).Value;

      // The whole point of the exercise: `arguments` is a JSON string cut
      // at arbitrary offsets. Concatenate the pieces verbatim and parse
      // once, at dispatch time.
      LValue := LFunc.FindValue('arguments');
      if Assigned(LValue) and (LValue is TJSONString) then
        LFrag.Arguments := LFrag.Arguments + TJSONString(LValue).Value;
    end;

    FFragments[LPos] := LFrag;
  end;
end;

procedure TMCPSSEAccumulator.ApplyUsage(AUsage: TJSONObject);
var
  LValue: TJSONValue;
begin
  LValue := AUsage.FindValue('prompt_tokens');
  if Assigned(LValue) and (LValue is TJSONNumber) then
  begin
    FPromptTokens := TJSONNumber(LValue).AsInt;
    FHasUsage := True;
  end;
  LValue := AUsage.FindValue('completion_tokens');
  if Assigned(LValue) and (LValue is TJSONNumber) then
  begin
    FCompletionTokens := TJSONNumber(LValue).AsInt;
    FHasUsage := True;
  end;
end;

function TMCPSSEAccumulator.BuildResponse: TJSONObject;
var
  I: Integer;
  LChoices, LToolCalls: TJSONArray;
  LChoice, LMessage, LToolCall, LFunc, LUsage: TJSONObject;
  LFinish: string;
begin
  Result := TJSONObject.Create;

  LChoices := TJSONArray.Create;
  Result.AddPair('choices', LChoices);

  LChoice := TJSONObject.Create;
  LChoices.AddElement(LChoice);
  LChoice.AddPair('index', TJSONNumber.Create(0));

  LMessage := TJSONObject.Create;
  LChoice.AddPair('message', LMessage);
  LMessage.AddPair('role', 'assistant');

  // Mirror the buffered shape exactly: content is null when the turn only
  // asked for tools, and the assistant message is replayed to the LLM as
  // history on the next turn.
  if FContent.Length > 0 then
    LMessage.AddPair('content', FContent.ToString)
  else
    LMessage.AddPair('content', TJSONNull.Create);

  if FFragments.Count > 0 then
  begin
    // Sort by index: chunks may interleave, the tool_calls array may not.
    FFragments.Sort(TComparer<TToolCallFragment>.Construct(
      function(const A, B: TToolCallFragment): Integer
      begin
        Result := A.Index - B.Index;
      end));

    LToolCalls := TJSONArray.Create;
    LMessage.AddPair('tool_calls', LToolCalls);
    for I := 0 to FFragments.Count - 1 do
    begin
      LToolCall := TJSONObject.Create;
      LToolCalls.AddElement(LToolCall);
      LToolCall.AddPair('id', FFragments[I].Id);
      LToolCall.AddPair('type', 'function');

      LFunc := TJSONObject.Create;
      LToolCall.AddPair('function', LFunc);
      LFunc.AddPair('name', FFragments[I].Name);
      LFunc.AddPair('arguments', FFragments[I].Arguments);
    end;
  end;

  // finish_reason is what the loop branches on, so never leave it empty:
  // tool fragments mean another turn, anything else means we are done.
  LFinish := FFinishReason;
  if LFinish = '' then
  begin
    if FFragments.Count > 0 then
      LFinish := 'tool_calls'
    else
      LFinish := 'stop';
  end;
  LChoice.AddPair('finish_reason', LFinish);

  if FHasUsage then
  begin
    LUsage := TJSONObject.Create;
    Result.AddPair('usage', LUsage);
    LUsage.AddPair('prompt_tokens',     TJSONNumber.Create(FPromptTokens));
    LUsage.AddPair('completion_tokens', TJSONNumber.Create(FCompletionTokens));
  end;
end;

function TMCPSSEAccumulator.HeadText: string;
begin
  Result := TEncoding.UTF8.GetString(FHead);
end;

function TMCPSSEAccumulator.IsEmpty: Boolean;
begin
  Result := (FContent.Length = 0) and (FFragments.Count = 0)
            and (FFinishReason = '') and (not FHasUsage);
end;

// ──────────────────────────────────────────────────────────────────────────
// TSSEResponseStream — the adapter between THTTPClient and the accumulator.
//
// THTTPClient writes the response body into the stream we hand it, in
// whatever pieces come off the socket. Overriding Write is therefore the
// whole streaming mechanism: no polling, no extra thread.
// ──────────────────────────────────────────────────────────────────────────

type
  TSSEResponseStream = class(TStream)
  private
    FAccumulator: TMCPSSEAccumulator;
    FPosition: Int64;
  public
    constructor Create(AAccumulator: TMCPSSEAccumulator);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

constructor TSSEResponseStream.Create(AAccumulator: TMCPSSEAccumulator);
begin
  inherited Create;
  FAccumulator := AAccumulator;
end;

function TSSEResponseStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;   // write-only sink
end;

function TSSEResponseStream.Write(const Buffer; Count: Longint): Longint;
var
  LChunk: TBytes;
begin
  Result := Count;
  if Count <= 0 then
    Exit;
  SetLength(LChunk, Count);
  Move(Buffer, LChunk[0], Count);
  FAccumulator.Feed(LChunk);
  Inc(FPosition, Count);
end;

function TSSEResponseStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  // THTTPClient only ever queries the position of the response stream.
  Result := FPosition;
end;

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
  FMCPClient           := nil;
  FOwnsMCPClient       := False;
  FStreaming           := False;
  FStreamUsage         := True;
  FOnContentDelta      := nil;

  FHTTP := THTTPClient.Create;
  FHTTP.ResponseTimeout   := FResponseTimeoutMs;
  FHTTP.ConnectionTimeout := FConnectionTimeoutMs;
end;

destructor TMCPOpenAIAgent.Destroy;
begin
  if FOwnsMCPClient and Assigned(FMCPClient) then
    FMCPClient.Free;
  FHTTP.Free;
  inherited;
end;

procedure TMCPOpenAIAgent.SetMCPClient(AClient: TMCPClientBase; AOwns: Boolean);
begin
  // If we previously owned a different client, free it before swapping.
  if FOwnsMCPClient and Assigned(FMCPClient) and (FMCPClient <> AClient) then
    FMCPClient.Free;
  FMCPClient := AClient;
  FOwnsMCPClient := AOwns;
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

function TMCPOpenAIAgent.BuildRequestBody(AMessages, ATools: TJSONArray;
  AStreaming: Boolean): TJSONObject;
var
  LStreamOptions: TJSONObject;
begin
  // We clone messages and tools: AddPair transfers ownership to the body,
  // and freeing the body at the end would otherwise destroy the caller's
  // structures. Cloning keeps the ownership story trivial.
  Result := TJSONObject.Create;
  Result.AddPair('model',    FModel);
  Result.AddPair('messages', AMessages.Clone as TJSONArray);
  if Assigned(ATools) and (ATools.Count > 0) then
    Result.AddPair('tools', ATools.Clone as TJSONArray);

  if AStreaming then
  begin
    Result.AddPair('stream', TJSONBool.Create(True));
    if FStreamUsage then
    begin
      LStreamOptions := TJSONObject.Create;
      LStreamOptions.AddPair('include_usage', TJSONBool.Create(True));
      Result.AddPair('stream_options', LStreamOptions);
    end;
  end;
end;

function TMCPOpenAIAgent.BuildHeaders(AStreaming: Boolean): TNetHeaders;
begin
  Result := [
    TNameValuePair.Create('Authorization', 'Bearer ' + FAPIKey),
    TNameValuePair.Create('Content-Type',  'application/json')
  ];
  if AStreaming then
    Result := Result + [TNameValuePair.Create('Accept', 'text/event-stream')];
  if FHTTPReferer <> '' then
    Result := Result + [TNameValuePair.Create('HTTP-Referer', FHTTPReferer)];
  if FXTitle <> '' then
    Result := Result + [TNameValuePair.Create('X-Title', FXTitle)];
end;

function TMCPOpenAIAgent.BuildURL: string;
begin
  // Tolerate a trailing slash in the base URL — some reverse proxies reject
  // double slashes.
  Result := FBaseURL;
  if (Result <> '') and (Result[Length(Result)] = '/') then
    SetLength(Result, Length(Result) - 1);
  Result := Result + '/chat/completions';
end;

function TMCPOpenAIAgent.CallLLM(AMessages, ATools: TJSONArray): TJSONObject;
var
  LBody: TJSONObject;
  LStream: TStringStream;
  LResp: IHTTPResponse;
  LValue: TJSONValue;
begin
  LBody := BuildRequestBody(AMessages, ATools, False);
  try
    LStream := TStringStream.Create(LBody.ToJSON, TEncoding.UTF8);
    try
      LResp := FHTTP.Post(BuildURL, LStream, nil, BuildHeaders(False));
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
// POST /chat/completions with stream: true
//
// The response body is consumed as it arrives by TSSEResponseStream, which
// forwards every chunk to the accumulator. What comes back out is the same
// envelope CallLLM returns, so Run treats both identically.
// ──────────────────────────────────────────────────────────────────────────

function TMCPOpenAIAgent.CallLLMStreaming(AMessages, ATools: TJSONArray): TJSONObject;
var
  LBody: TJSONObject;
  LSource: TStringStream;
  LSink: TSSEResponseStream;
  LAccumulator: TMCPSSEAccumulator;
  LResp: IHTTPResponse;
begin
  LAccumulator := TMCPSSEAccumulator.Create(FOnContentDelta);
  try
    LBody := BuildRequestBody(AMessages, ATools, True);
    try
      LSource := TStringStream.Create(LBody.ToJSON, TEncoding.UTF8);
      try
        LSink := TSSEResponseStream.Create(LAccumulator);
        try
          LResp := FHTTP.Post(BuildURL, LSource, LSink, BuildHeaders(True));
        finally
          LSink.Free;
        end;
      finally
        LSource.Free;
      end;
    finally
      LBody.Free;
    end;

    // The body went into our sink, so ContentAsString is empty here: an
    // error response is JSON rather than SSE, and the accumulator kept its
    // opening bytes precisely for this message.
    if (LResp.StatusCode < 200) or (LResp.StatusCode >= 300) then
      raise Exception.CreateFmt('LLM HTTP %d: %s',
        [LResp.StatusCode, Copy(LAccumulator.HeadText, 1, 800)]);

    LAccumulator.Flush;

    // Nothing parsed and no [DONE] means we were not talking to an event
    // stream at all (a proxy that buffered the body into plain JSON, a
    // provider that ignored `stream`). Fail loudly: BuildResponse would
    // otherwise hand the loop an empty answer that looks like a perfectly
    // well-behaved "stop", and Run would return "" as the final content.
    if (not LAccumulator.Done) and LAccumulator.IsEmpty then
      raise Exception.Create('LLM streaming response was not an event stream: ' +
        Copy(LAccumulator.HeadText, 1, 800));

    Result := LAccumulator.BuildResponse;
  finally
    LAccumulator.Free;
  end;
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
  AMCP: TMCPClientBase; AWorking: TJSONArray; var AStats: TMCPAgentResult);
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
  LMCP: TMCPClientBase;
  LOwnedHere: Boolean;
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

  // 1. MCP client. Use the injected one if the caller set it via
  //    SetMCPClient (e.g. a TMCPStdioClient that wraps a child process);
  //    otherwise spin up a fresh HTTP TMCPClient pointing at FMCPURL — the
  //    backward-compatible behaviour.
  if Assigned(FMCPClient) then
  begin
    LMCP := FMCPClient;
    LOwnedHere := False;
  end
  else
  begin
    LMCP := TMCPClient.Create(FMCPURL);
    LOwnedHere := True;
  end;
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
            // Both paths return the same envelope shape, so everything
            // below is blind to which transport produced it.
            if FStreaming then
              LResp := CallLLMStreaming(LWorking, LTools)
            else
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
    if LOwnedHere then
      LMCP.Free;
  end;
end;

end.
