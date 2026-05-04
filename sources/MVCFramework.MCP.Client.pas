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
  TMCPClient — Minimal MCP client over Streamable HTTP transport.

  -- What this is --
  Companion to the server-side units of this library: anything you need to
  talk TO an MCP server (Claude Desktop, this library's own server, any other
  spec-compliant implementation) from a Delphi application.

  Built on JSON-RPC 2.0 over a single POST per request. The optional GET SSE
  channel of the spec is not used — the server replies in the POST body and
  there is no server-initiated streaming.

  -- JSON-RPC envelope shape --
    request   { "jsonrpc":"2.0", "id":1, "method":"tools/list", "params":{} }
    response  { "jsonrpc":"2.0", "id":1, "result":{ ... } }
    notify    { "jsonrpc":"2.0",        "method":"notifications/initialized" }
  Notifications carry no "id" and receive no response.

  -- Session lifecycle --
  The first response carries an `Mcp-Session-Id` header. The client memorizes
  it and replays it on every subsequent request so the server can correlate
  state across calls. DELETE on the endpoint destroys the session (not
  implemented here — the spec considers it optional).

  -- JSON ownership conventions --
  This unit uses `System.JSON` (TJSONObject / TJSONArray) which has no ARC
  for JSON values. The conventions are:
    * Methods that take a TJSONObject parameter CONSUME it (free it on the
      caller's behalf). Mirrors `TJSONObject.AddPair` semantics.
    * Methods that return a TJSONObject / TJSONArray transfer ownership to
      the CALLER, which is responsible for freeing the result.
  ============================================================================ *)

unit MVCFramework.MCP.Client;

interface

uses
  System.Classes,
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.URLClient;

type
  TMCPClient = class
  private
    FURL: string;          // MCP server endpoint (e.g. http://127.0.0.1:8080/mcp)
    FSessionID: string;    // Set after the first POST (Mcp-Session-Id header)
    FRequestID: Integer;   // Monotonic counter for the JSON-RPC "id" field
    FHTTP: THTTPClient;    // Reused for all calls
    FProtocolVersion: string;
    FClientName: string;
    FClientVersion: string;
    FResponseTimeoutMs: Integer;
    FConnectionTimeoutMs: Integer;

    function NextID: Integer;
    function BuildHeaders: TNetHeaders;

    // Performs a single JSON-RPC request. AParams is CONSUMED.
    // If ANotify=True the call returns immediately with no response object.
    function RPC(const AMethod: string; AParams: TJSONObject;
      ANotify: Boolean = False): TJSONObject;
  public
    constructor Create(const AURL: string);
    destructor Destroy; override;

    // MCP handshake: "initialize" + "notifications/initialized".
    // Must be called once before any tools/* or resources/* or prompts/* call.
    procedure Initialize;

    // ---- Tools --------------------------------------------------------------

    // Returns the array of tool descriptors {name, description, inputSchema}.
    // Ownership transferred to caller.
    function ListTools: TJSONArray;

    // Invokes a tool and returns the concatenated text of every "content"
    // block returned by the server. Non-text blocks (image, resource, ...)
    // are appended as raw JSON. AArguments is CONSUMED.
    function CallTool(const AName: string; AArguments: TJSONObject): string;

    // ---- Resources ----------------------------------------------------------

    // Returns the array of static resource descriptors {uri, name, description, mimeType}
    // exposed via resources/list. Ownership transferred to caller.
    function ListResources: TJSONArray;

    // Returns the array of templated resource descriptors {uriTemplate, name,
    // description, mimeType} exposed via resources/templates/list (RFC 6570
    // Level 1 templates). Ownership transferred to caller.
    function ListResourceTemplates: TJSONArray;

    // Reads a resource by URI. The URI may be a static one or the concretized
    // form of a template (e.g. "user://42" matching "user://{id}").
    // Concatenates the "text" content of every contents block; for blob
    // contents, emits a placeholder mentioning the base64 length. Sets
    // AMimeType to the MIME type of the first contents block, when present.
    function ReadResource(const AURI: string; out AMimeType: string): string;

    // ---- Prompts ------------------------------------------------------------

    // Returns the array of prompt descriptors {name, description, arguments}
    // exposed via prompts/list. Ownership transferred to caller.
    function ListPrompts: TJSONArray;

    // Renders a prompt by name and returns its messages array
    // [{role, content}, ...] suitable for forwarding to an LLM.
    // AArguments is CONSUMED. Ownership of the returned array transferred
    // to caller. AArguments may be nil for argument-less prompts.
    function GetPrompt(const AName: string; AArguments: TJSONObject): TJSONArray;

    // ---- Configuration ------------------------------------------------------

    // Server endpoint. Read-only after construction.
    property URL: string read FURL;
    // Mcp-Session-Id captured after the first response.
    property SessionID: string read FSessionID;
    // Protocol version sent during initialize (defaults to MCP_PROTOCOL_VERSION).
    property ProtocolVersion: string read FProtocolVersion write FProtocolVersion;
    // clientInfo.name sent during initialize.
    property ClientName: string read FClientName write FClientName;
    // clientInfo.version sent during initialize.
    property ClientVersion: string read FClientVersion write FClientVersion;
    // Response timeout (ms) for HTTP calls. Default 300000 (5 min) — generous
    // because tools may include long-running operations or human-in-the-loop
    // steps. Decrease for stricter SLAs.
    property ResponseTimeoutMs: Integer read FResponseTimeoutMs write FResponseTimeoutMs;
    // Connection timeout (ms). Default 10000 — fail fast if the server is down.
    property ConnectionTimeoutMs: Integer read FConnectionTimeoutMs write FConnectionTimeoutMs;
  end;

implementation

uses
  MVCFramework.MCP.Types;

// ──────────────────────────────────────────────────────────────────────────
// Construction / destruction
// ──────────────────────────────────────────────────────────────────────────

constructor TMCPClient.Create(const AURL: string);
begin
  inherited Create;
  FURL := AURL;
  FSessionID := '';
  FRequestID := 0;
  FProtocolVersion := MCP_PROTOCOL_VERSION;
  FClientName := 'MVCFramework.MCP.Client';
  FClientVersion := '1.0';
  FResponseTimeoutMs := 300000;
  FConnectionTimeoutMs := 10000;

  FHTTP := THTTPClient.Create;
  FHTTP.ResponseTimeout   := FResponseTimeoutMs;
  FHTTP.ConnectionTimeout := FConnectionTimeoutMs;
end;

destructor TMCPClient.Destroy;
begin
  FHTTP.Free;
  inherited;
end;

// ──────────────────────────────────────────────────────────────────────────
// Private helpers
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.NextID: Integer;
begin
  Inc(FRequestID);
  Result := FRequestID;
end;

function TMCPClient.BuildHeaders: TNetHeaders;
begin
  // Content-Type: we always send JSON.
  // Accept: server may answer in plain JSON or in SSE — we accept either,
  // but our reader is single-shot (no streaming), so the server is expected
  // to put the JSON-RPC response in the POST body.
  Result := [
    TNameValuePair.Create('Content-Type', 'application/json'),
    TNameValuePair.Create('Accept', 'application/json, text/event-stream')
  ];

  // Replay the session id on every subsequent request.
  if FSessionID <> '' then
    Result := Result + [TNameValuePair.Create('Mcp-Session-Id', FSessionID)];
end;

// ──────────────────────────────────────────────────────────────────────────
// Core: a single JSON-RPC roundtrip
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.RPC(const AMethod: string; AParams: TJSONObject;
  ANotify: Boolean): TJSONObject;
var
  LBody: TJSONObject;
  LStream: TStringStream;
  LResp: IHTTPResponse;
  LSID, LRespBody: string;
  LValue: TJSONValue;
begin
  Result := nil;

  // 1) Build the JSON-RPC payload.
  LBody := TJSONObject.Create;
  try
    LBody.AddPair('jsonrpc', '2.0');
    LBody.AddPair('method',  AMethod);

    // "params" is mandatory in this implementation: if the caller does not
    // pass anything, send an empty object. AddPair transfers ownership of
    // AParams to LBody, so we don't free AParams separately.
    if Assigned(AParams) then
      LBody.AddPair('params', AParams)
    else
      LBody.AddPair('params', TJSONObject.Create);

    // Requests carry a unique numeric "id"; notifications don't.
    // The server distinguishes them by the absence of "id".
    if not ANotify then
      LBody.AddPair('id', TJSONNumber.Create(NextID));

    // 2) Synchronous POST.
    LStream := TStringStream.Create(LBody.ToJSON, TEncoding.UTF8);
    try
      LResp := FHTTP.Post(FURL, LStream, nil, BuildHeaders);
    finally
      LStream.Free;
    end;
  finally
    // Freeing LBody also frees AParams (now its child).
    LBody.Free;
  end;

  // 3) HTTP validation.
  if (LResp.StatusCode < 200) or (LResp.StatusCode >= 300) then
    raise Exception.CreateFmt('MCP HTTP %d on %s: %s',
      [LResp.StatusCode, AMethod,
       Copy(LResp.ContentAsString, 1, 400)]);

  // 4) Capture the session id (if this is the first response).
  LSID := LResp.HeaderValue['mcp-session-id'];
  if LSID <> '' then
    FSessionID := LSID;

  // Notifications don't carry a meaningful body.
  if ANotify then
    Exit;

  // The server may answer with an empty body (e.g. ack of a hidden
  // notification). Return nil in that case.
  LRespBody := LResp.ContentAsString;
  if Trim(LRespBody) = '' then
    Exit;

  // 5) Parse the body.
  LValue := TJSONObject.ParseJSONValue(LRespBody);
  if not (LValue is TJSONObject) then
  begin
    // Defensive: free what we got before raising, to avoid the leak.
    if Assigned(LValue) then
      LValue.Free;
    raise Exception.CreateFmt('MCP returned non-JSON-object on %s', [AMethod]);
  end;

  Result := TJSONObject(LValue); // ownership transferred to caller

  // 6) JSON-RPC error envelope. Transport-level OK (HTTP 200) but the
  // server signaled a protocol-level failure: { jsonrpc, id, error: {
  // code, message } }. We surface it to the caller as an exception so
  // higher-level methods don't silently fall back to "(no result)" — that
  // would mask real failures (unknown tool, invalid args, server-side raise).
  LValue := Result.FindValue('error');
  if Assigned(LValue) and (LValue is TJSONObject) then
  begin
    LRespBody := Format('MCP %s error %d: %s',
      [AMethod,
       TJSONObject(LValue).GetValue<Integer>('code', 0),
       TJSONObject(LValue).GetValue<string>('message', '<no message>')]);
    Result.Free;
    raise Exception.Create(LRespBody);
  end;
end;

// ──────────────────────────────────────────────────────────────────────────
// MCP handshake
//
// Protocol requires:
//   1) request  "initialize"               → server returns capabilities
//   2) notify   "notifications/initialized" (no id, no response)
// Only after this pair the client may invoke tools/list, tools/call, etc.
// ──────────────────────────────────────────────────────────────────────────

procedure TMCPClient.Initialize;
var
  LParams, LCaps, LInfo: TJSONObject;
  LResp: TJSONObject;
begin
  LParams := TJSONObject.Create;
  LParams.AddPair('protocolVersion', FProtocolVersion);

  LCaps := TJSONObject.Create; // empty client capabilities
  LParams.AddPair('capabilities', LCaps);

  LInfo := TJSONObject.Create;
  LInfo.AddPair('name',    FClientName);
  LInfo.AddPair('version', FClientVersion);
  LParams.AddPair('clientInfo', LInfo);

  LResp := RPC('initialize', LParams);
  if Assigned(LResp) then
    LResp.Free; // server capabilities not exposed yet — discarded

  // Notification: no "id", no response expected.
  RPC('notifications/initialized', TJSONObject.Create, True);
end;

// ──────────────────────────────────────────────────────────────────────────
// tools/list
//
// Typical response shape:
//   { "result": { "tools": [ {name, description, inputSchema}, ... ] } }
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.ListTools: TJSONArray;
var
  LResp, LResult: TJSONObject;
  LTools: TJSONArray;
begin
  Result := nil;
  LResp := RPC('tools/list', TJSONObject.Create);
  try
    if not Assigned(LResp) then Exit;
    LResult := LResp.GetValue('result') as TJSONObject;
    if not Assigned(LResult) then Exit;
    LTools := LResult.GetValue('tools') as TJSONArray;
    // Clone: LTools is a child of LResp and will be freed in the finally;
    // returning it as-is would leave a dangling reference.
    if Assigned(LTools) then
      Result := LTools.Clone as TJSONArray;
  finally
    LResp.Free;
  end;
  if not Assigned(Result) then
    Result := TJSONArray.Create;
end;

// ──────────────────────────────────────────────────────────────────────────
// tools/call
//
// Typical response shape:
//   { "result": { "content": [ {"type":"text","text":"..."}, ... ] } }
// Multiple blocks are joined with line breaks for ergonomic consumption.
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.CallTool(const AName: string; AArguments: TJSONObject): string;
var
  LParams, LResp, LResult, LItem: TJSONObject;
  LContent: TJSONArray;
  LSB: TStringBuilder;
  I: Integer;
  LTextValue: TJSONValue;
begin
  // Wrap the arguments in the shape the protocol expects.
  LParams := TJSONObject.Create;
  LParams.AddPair('name', AName);
  if Assigned(AArguments) then
    LParams.AddPair('arguments', AArguments)
  else
    LParams.AddPair('arguments', TJSONObject.Create);

  LResp := RPC('tools/call', LParams);
  try
    if not Assigned(LResp) then Exit('(no result)');
    LResult := LResp.GetValue('result') as TJSONObject;
    if not Assigned(LResult) then Exit('(no result)');
    LContent := LResult.GetValue('content') as TJSONArray;
    if (not Assigned(LContent)) or (LContent.Count = 0) then
      Exit('(no result)');

    LSB := TStringBuilder.Create;
    try
      for I := 0 to LContent.Count - 1 do
      begin
        if I > 0 then
          LSB.AppendLine;

        // Non-object blocks (rare): dump as raw JSON.
        if not (LContent.Items[I] is TJSONObject) then
        begin
          LSB.Append(LContent.Items[I].ToJSON);
          Continue;
        end;

        LItem := TJSONObject(LContent.Items[I]);

        // Common case: { "type":"text", "text":"..." }.
        // Use FindValue + type check rather than GetValue<string> so we
        // fall back gracefully when "text" is missing or null.
        LTextValue := LItem.FindValue('text');
        if Assigned(LTextValue) and (LTextValue is TJSONString) then
          LSB.Append(TJSONString(LTextValue).Value)
        else
          LSB.Append(LItem.ToJSON); // image / audio / resource block → raw JSON
      end;
      Result := LSB.ToString;
    finally
      LSB.Free;
    end;
  finally
    LResp.Free;
  end;
end;

// ──────────────────────────────────────────────────────────────────────────
// resources/list — static resources (concrete URIs)
//
// Typical response shape:
//   { "result": { "resources": [ {uri, name, description, mimeType}, ... ] } }
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.ListResources: TJSONArray;
var
  LResp, LResult: TJSONObject;
  LArr: TJSONArray;
begin
  Result := nil;
  LResp := RPC('resources/list', TJSONObject.Create);
  try
    if not Assigned(LResp) then Exit;
    LResult := LResp.GetValue('result') as TJSONObject;
    if not Assigned(LResult) then Exit;
    LArr := LResult.GetValue('resources') as TJSONArray;
    if Assigned(LArr) then
      Result := LArr.Clone as TJSONArray;
  finally
    LResp.Free;
  end;
  if not Assigned(Result) then
    Result := TJSONArray.Create;
end;

// ──────────────────────────────────────────────────────────────────────────
// resources/templates/list — templated resources (URI with {placeholder})
//
// Typical response shape:
//   { "result": { "resourceTemplates": [
//       {uriTemplate, name, description, mimeType}, ... ] } }
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.ListResourceTemplates: TJSONArray;
var
  LResp, LResult: TJSONObject;
  LArr: TJSONArray;
begin
  Result := nil;
  LResp := RPC('resources/templates/list', TJSONObject.Create);
  try
    if not Assigned(LResp) then Exit;
    LResult := LResp.GetValue('result') as TJSONObject;
    if not Assigned(LResult) then Exit;
    LArr := LResult.GetValue('resourceTemplates') as TJSONArray;
    if Assigned(LArr) then
      Result := LArr.Clone as TJSONArray;
  finally
    LResp.Free;
  end;
  if not Assigned(Result) then
    Result := TJSONArray.Create;
end;

// ──────────────────────────────────────────────────────────────────────────
// resources/read — read a resource by URI
//
// Typical response shape:
//   { "result": { "contents": [
//       { "uri":"...", "mimeType":"...", "text":"..." }, ... ] } }
// Blob resources have "blob" (base64) instead of "text". Almost every
// resource has a single contents block; we still concatenate just in case.
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.ReadResource(const AURI: string; out AMimeType: string): string;
var
  LParams, LResp, LResult, LItem: TJSONObject;
  LContents: TJSONArray;
  LSB: TStringBuilder;
  I: Integer;
  LTextValue, LBlobValue: TJSONValue;
begin
  AMimeType := '';
  LParams := TJSONObject.Create;
  LParams.AddPair('uri', AURI);

  LResp := RPC('resources/read', LParams);
  try
    if not Assigned(LResp) then Exit('(no result)');
    LResult := LResp.GetValue('result') as TJSONObject;
    if not Assigned(LResult) then Exit('(no result)');
    LContents := LResult.GetValue('contents') as TJSONArray;
    if (not Assigned(LContents)) or (LContents.Count = 0) then
      Exit('(empty contents)');

    LSB := TStringBuilder.Create;
    try
      for I := 0 to LContents.Count - 1 do
      begin
        if I > 0 then LSB.AppendLine;
        if not (LContents.Items[I] is TJSONObject) then
        begin
          LSB.Append(LContents.Items[I].ToJSON);
          Continue;
        end;
        LItem := TJSONObject(LContents.Items[I]);

        // Capture the MIME of the first item for downstream rendering.
        if AMimeType = '' then
        begin
          LTextValue := LItem.FindValue('mimeType');
          if Assigned(LTextValue) and (LTextValue is TJSONString) then
            AMimeType := TJSONString(LTextValue).Value;
        end;

        LTextValue := LItem.FindValue('text');
        if Assigned(LTextValue) and (LTextValue is TJSONString) then
          LSB.Append(TJSONString(LTextValue).Value)
        else
        begin
          LBlobValue := LItem.FindValue('blob');
          if Assigned(LBlobValue) and (LBlobValue is TJSONString) then
            LSB.AppendFormat('(blob, %d base64 chars)',
              [Length(TJSONString(LBlobValue).Value)])
          else
            LSB.Append(LItem.ToJSON);
        end;
      end;
      Result := LSB.ToString;
    finally
      LSB.Free;
    end;
  finally
    LResp.Free;
  end;
end;

// ──────────────────────────────────────────────────────────────────────────
// prompts/list
//
// Typical response shape:
//   { "result": { "prompts": [
//       {name, description, arguments: [{name, description, required}, ...]},
//       ... ] } }
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.ListPrompts: TJSONArray;
var
  LResp, LResult: TJSONObject;
  LArr: TJSONArray;
begin
  Result := nil;
  LResp := RPC('prompts/list', TJSONObject.Create);
  try
    if not Assigned(LResp) then Exit;
    LResult := LResp.GetValue('result') as TJSONObject;
    if not Assigned(LResult) then Exit;
    LArr := LResult.GetValue('prompts') as TJSONArray;
    if Assigned(LArr) then
      Result := LArr.Clone as TJSONArray;
  finally
    LResp.Free;
  end;
  if not Assigned(Result) then
    Result := TJSONArray.Create;
end;

// ──────────────────────────────────────────────────────────────────────────
// prompts/get — render a prompt with the supplied arguments
//
// Typical response shape:
//   { "result": { "description":"...", "messages": [
//       {"role":"user", "content":{"type":"text","text":"..."}}, ... ] } }
//
// Returns the messages array. Description is intentionally dropped here —
// it is a hint for the developer / UI, not for the LLM. Use ListPrompts to
// retrieve the description if needed.
// ──────────────────────────────────────────────────────────────────────────

function TMCPClient.GetPrompt(const AName: string;
  AArguments: TJSONObject): TJSONArray;
var
  LParams, LResp, LResult: TJSONObject;
  LArr: TJSONArray;
begin
  LParams := TJSONObject.Create;
  LParams.AddPair('name', AName);
  if Assigned(AArguments) then
    LParams.AddPair('arguments', AArguments)
  else
    LParams.AddPair('arguments', TJSONObject.Create);

  Result := nil;
  LResp := RPC('prompts/get', LParams);
  try
    if not Assigned(LResp) then Exit;
    LResult := LResp.GetValue('result') as TJSONObject;
    if not Assigned(LResult) then Exit;
    LArr := LResult.GetValue('messages') as TJSONArray;
    if Assigned(LArr) then
      Result := LArr.Clone as TJSONArray;
  finally
    LResp.Free;
  end;
  if not Assigned(Result) then
    Result := TJSONArray.Create;
end;

end.
