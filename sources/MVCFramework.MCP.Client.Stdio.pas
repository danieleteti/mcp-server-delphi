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
  TMCPStdioClient - MCP client over stdio transport.

  -- What this is --
  Companion to TMCPClient (HTTP). Spawns a stdio MCP server as a child
  process and talks to it over its stdin/stdout via line-delimited
  JSON-RPC 2.0. Same public surface as TMCPClient (via the shared
  TMCPClientBase ancestor), so TMCPOpenAIAgent and any other generic
  consumer works against either transport without code changes.

  -- Wire framing --
  Each JSON-RPC message is one UTF-8-encoded JSON object terminated by
  a single LF (0x0A). CR is tolerated on read (some servers emit CRLF).
  This matches the framing implemented by MVCFramework.MCP.Stdio on the
  server side and by the reference Python MCP SDK.

  -- Transport caveats --
  * Anonymous Win32 pipes are used for stdin / stdout. Synchronous reads
    with PeekNamedPipe + Sleep(10) polling provide a coarse-grained
    timeout; sufficient for interactive workloads, not for high-frequency
    RPC fan-out.
  * The child's stderr is left untouched (inherits the parent's), so any
    log output the server may emit on stderr appears in the parent
    console — mirrors how Claude Desktop and similar clients run stdio
    servers. The server is expected to keep stdout JSON-RPC clean (this
    is what the loggerpro.stdio.json profile enforces in the bundled
    sample / testproject).
  * On destruction we politely close stdin (signaling EOF to the server)
    then wait up to 2 seconds for graceful exit. If the server is still
    alive after the grace period it gets TerminateProcess'd.

  -- JSON ownership --
  Same convention as TMCPClient: methods that take a TJSONObject CONSUME
  it; methods that return one transfer ownership to the caller.
  ============================================================================ *)

unit MVCFramework.MCP.Client.Stdio;

interface

uses
  Winapi.Windows,
  System.Classes,
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MVCFramework.MCP.Client;

type
  TMCPStdioClient = class(TMCPClientBase)
  private
    FCommandLine: string;
    FStdInWrite: THandle;
    FStdOutRead: THandle;
    FProcHandle: THandle;
    FProcId: DWORD;
    FResponseTimeoutMs: Integer;
    FRecvBuf: TBytes;        // Bytes already read from stdout but not yet consumed.
    FInitialized: Boolean;

    procedure SpawnProcess;
    procedure CloseProcess;
    function IsProcessAlive: Boolean;
    function HasDataAvailable: Boolean;
    function FillBuffer(ATimeoutMs: Integer): Boolean; // returns False on timeout/EOF
    function ReadLine(ATimeoutMs: Integer): string;
    procedure WriteLine(const AJson: string);

    // Performs a single JSON-RPC request. AParams is CONSUMED. If ANotify
    // is True the call returns immediately (no response read).
    function RPC(const AMethod: string; AParams: TJSONObject;
      ANotify: Boolean = False): TJSONObject;
  public
    constructor Create(const ACommandLine: string); reintroduce;
    destructor Destroy; override;

    procedure Initialize; override;
    function ListTools: TJSONArray; override;
    function CallTool(const AName: string; AArguments: TJSONObject): string; override;
    function ListResources: TJSONArray; override;
    function ListResourceTemplates: TJSONArray; override;
    function ReadResource(const AURI: string; out AMimeType: string): string; override;
    function ListPrompts: TJSONArray; override;
    function GetPrompt(const AName: string; AArguments: TJSONObject): TJSONArray; override;

    // Full command line (with arguments) used to spawn the server.
    property CommandLine: string read FCommandLine;
    // Per-RPC response timeout in milliseconds. Default 300000 (5 min) —
    // matches the HTTP client and is generous because tools may include
    // long-running operations or human-in-the-loop steps.
    property ResponseTimeoutMs: Integer read FResponseTimeoutMs write FResponseTimeoutMs;
  end;

implementation

uses
  MVCFramework.MCP.Types;

const
  RECV_CHUNK = 4096;

// ──────────────────────────────────────────────────────────────────────────
// Construction / destruction
// ──────────────────────────────────────────────────────────────────────────

constructor TMCPStdioClient.Create(const ACommandLine: string);
begin
  inherited Create;
  FCommandLine         := ACommandLine;
  FResponseTimeoutMs   := 300000;
  FStdInWrite          := INVALID_HANDLE_VALUE;
  FStdOutRead          := INVALID_HANDLE_VALUE;
  FProcHandle          := 0;
  FProcId              := 0;
  FInitialized         := False;
  SetLength(FRecvBuf, 0);
  SpawnProcess;
end;

destructor TMCPStdioClient.Destroy;
begin
  CloseProcess;
  inherited;
end;

// ──────────────────────────────────────────────────────────────────────────
// Subprocess lifecycle
// ──────────────────────────────────────────────────────────────────────────

procedure TMCPStdioClient.SpawnProcess;
var
  LSecAttr: TSecurityAttributes;
  LStdInRead: THandle;
  LStdOutWrite: THandle;
  LStartupInfo: TStartupInfo;
  LProcInfo: TProcessInformation;
  LCmdBuf: array[0..32767] of Char;
  LParentStdErr: THandle;
begin
  LSecAttr.nLength := SizeOf(LSecAttr);
  LSecAttr.bInheritHandle := True;
  LSecAttr.lpSecurityDescriptor := nil;

  // stdin pipe: child reads, parent writes.
  if not CreatePipe(LStdInRead, FStdInWrite, @LSecAttr, 0) then
    RaiseLastOSError;
  // The parent side of the stdin pipe must NOT be inheritable, otherwise
  // the child receives an extra handle and the EOF on close-handle never
  // arrives.
  SetHandleInformation(FStdInWrite, HANDLE_FLAG_INHERIT, 0);

  // stdout pipe: child writes, parent reads.
  if not CreatePipe(FStdOutRead, LStdOutWrite, @LSecAttr, 0) then
  begin
    CloseHandle(LStdInRead);
    CloseHandle(FStdInWrite);
    FStdInWrite := INVALID_HANDLE_VALUE;
    RaiseLastOSError;
  end;
  SetHandleInformation(FStdOutRead, HANDLE_FLAG_INHERIT, 0);

  // Inherit our own stderr so the child's logs appear in our console.
  // GetStdHandle returns 0 if the parent has no stderr (rare).
  LParentStdErr := GetStdHandle(STD_ERROR_HANDLE);

  ZeroMemory(@LStartupInfo, SizeOf(LStartupInfo));
  LStartupInfo.cb := SizeOf(LStartupInfo);
  LStartupInfo.dwFlags := STARTF_USESTDHANDLES;
  LStartupInfo.hStdInput  := LStdInRead;
  LStartupInfo.hStdOutput := LStdOutWrite;
  LStartupInfo.hStdError  := LParentStdErr;

  // CreateProcess wants a writable command-line buffer.
  StrPLCopy(LCmdBuf, FCommandLine, Length(LCmdBuf) - 1);

  if not CreateProcess(
    nil, LCmdBuf, nil, nil,
    True,           // bInheritHandles
    0,              // dwCreationFlags (no CREATE_NO_WINDOW so console servers stay visible)
    nil, nil, LStartupInfo, LProcInfo) then
  begin
    CloseHandle(LStdInRead);
    CloseHandle(LStdOutWrite);
    CloseHandle(FStdInWrite);
    FStdInWrite := INVALID_HANDLE_VALUE;
    CloseHandle(FStdOutRead);
    FStdOutRead := INVALID_HANDLE_VALUE;
    RaiseLastOSError;
  end;

  FProcHandle := LProcInfo.hProcess;
  FProcId     := LProcInfo.dwProcessId;
  CloseHandle(LProcInfo.hThread);

  // Close the child-side pipe ends on the parent — only the child needs
  // them. Without this, our reads on FStdOutRead would never see EOF
  // because we'd still hold a write handle.
  CloseHandle(LStdInRead);
  CloseHandle(LStdOutWrite);
end;

procedure TMCPStdioClient.CloseProcess;
const
  GRACE_MS = 2000;
var
  LWait: DWORD;
begin
  // Closing stdin signals EOF to the server: well-behaved stdio servers
  // exit cleanly when their stdin is closed.
  if FStdInWrite <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FStdInWrite);
    FStdInWrite := INVALID_HANDLE_VALUE;
  end;

  if FProcHandle <> 0 then
  begin
    LWait := WaitForSingleObject(FProcHandle, GRACE_MS);
    if LWait = WAIT_TIMEOUT then
      TerminateProcess(FProcHandle, 1);
    CloseHandle(FProcHandle);
    FProcHandle := 0;
    FProcId := 0;
  end;

  if FStdOutRead <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FStdOutRead);
    FStdOutRead := INVALID_HANDLE_VALUE;
  end;
end;

function TMCPStdioClient.IsProcessAlive: Boolean;
var
  LCode: DWORD;
begin
  if FProcHandle = 0 then
    Exit(False);
  if not GetExitCodeProcess(FProcHandle, LCode) then
    Exit(False);
  Result := LCode = STILL_ACTIVE;
end;

// ──────────────────────────────────────────────────────────────────────────
// I/O primitives
// ──────────────────────────────────────────────────────────────────────────

function TMCPStdioClient.HasDataAvailable: Boolean;
var
  LAvail: DWORD;
begin
  Result := PeekNamedPipe(FStdOutRead, nil, 0, nil, @LAvail, nil)
            and (LAvail > 0);
end;

// Drains as many bytes as PeekNamedPipe reports available into FRecvBuf.
// Returns True if at least one byte was added; False on timeout (no data
// became available within ATimeoutMs) or on read failure.
function TMCPStdioClient.FillBuffer(ATimeoutMs: Integer): Boolean;
var
  LStart: Cardinal;
  LAvail: DWORD;
  LChunk: TBytes;
  LRead: DWORD;
begin
  LStart := GetTickCount;
  while True do
  begin
    if HasDataAvailable then
      Break;
    if not IsProcessAlive then
      Exit(False); // child died; treat as EOF
    if (ATimeoutMs >= 0)
       and (Integer(GetTickCount - LStart) >= ATimeoutMs) then
      Exit(False);
    Sleep(10);
  end;

  if not PeekNamedPipe(FStdOutRead, nil, 0, nil, @LAvail, nil) then
    Exit(False);
  if LAvail > RECV_CHUNK then
    LAvail := RECV_CHUNK;

  SetLength(LChunk, LAvail);
  if not ReadFile(FStdOutRead, LChunk[0], LAvail, LRead, nil) then
    Exit(False);
  if LRead = 0 then
    Exit(False);

  SetLength(LChunk, LRead);
  // Append to FRecvBuf.
  SetLength(FRecvBuf, Length(FRecvBuf) + Length(LChunk));
  Move(LChunk[0], FRecvBuf[Length(FRecvBuf) - Length(LChunk)], Length(LChunk));
  Result := True;
end;

function TMCPStdioClient.ReadLine(ATimeoutMs: Integer): string;
var
  I: Integer;
  LLineBytes: TBytes;
  LStart: Cardinal;
  LElapsed: Integer;
  LRemaining: Integer;
begin
  // Search for LF in FRecvBuf; if absent, refill from the pipe and try
  // again. The total wait across multiple FillBuffer calls is capped by
  // the original ATimeoutMs.
  LStart := GetTickCount;

  while True do
  begin
    for I := 0 to High(FRecvBuf) do
      if FRecvBuf[I] = 10 then // LF
      begin
        // Slice [0..I-1] (drop CR if it's there, drop LF), shift the rest
        // back to the front of FRecvBuf.
        if (I > 0) and (FRecvBuf[I - 1] = 13) then
          LLineBytes := Copy(FRecvBuf, 0, I - 1)
        else
          LLineBytes := Copy(FRecvBuf, 0, I);

        FRecvBuf := Copy(FRecvBuf, I + 1, Length(FRecvBuf) - I - 1);

        if Length(LLineBytes) = 0 then
          Exit('')
        else
          Exit(TEncoding.UTF8.GetString(LLineBytes));
      end;

    LElapsed := Integer(GetTickCount - LStart);
    if ATimeoutMs < 0 then
      LRemaining := -1
    else
    begin
      LRemaining := ATimeoutMs - LElapsed;
      if LRemaining <= 0 then
        raise Exception.Create(
          'TMCPStdioClient: timeout waiting for response from server');
    end;

    if not FillBuffer(LRemaining) then
      raise Exception.Create(
        'TMCPStdioClient: server pipe closed or unreadable (process dead?)');
  end;
end;

procedure TMCPStdioClient.WriteLine(const AJson: string);
var
  LBytes: TBytes;
  LWritten: DWORD;
begin
  // Frame: UTF-8 of the JSON, plus a single LF.
  LBytes := TEncoding.UTF8.GetBytes(AJson);
  SetLength(LBytes, Length(LBytes) + 1);
  LBytes[High(LBytes)] := 10; // LF

  if not WriteFile(FStdInWrite, LBytes[0], Length(LBytes), LWritten, nil)
     or (LWritten <> DWORD(Length(LBytes))) then
    raise Exception.Create('TMCPStdioClient: failed to write to server stdin');
end;

// ──────────────────────────────────────────────────────────────────────────
// Core JSON-RPC roundtrip
// ──────────────────────────────────────────────────────────────────────────

function TMCPStdioClient.RPC(const AMethod: string; AParams: TJSONObject;
  ANotify: Boolean): TJSONObject;
var
  LBody: TJSONObject;
  LRespLine: string;
  LValue: TJSONValue;
begin
  Result := nil;

  LBody := TJSONObject.Create;
  try
    LBody.AddPair('jsonrpc', '2.0');
    LBody.AddPair('method',  AMethod);
    if Assigned(AParams) then
      LBody.AddPair('params', AParams)
    else
      LBody.AddPair('params', TJSONObject.Create);
    if not ANotify then
      LBody.AddPair('id', TJSONNumber.Create(NextID));

    WriteLine(LBody.ToJSON);
  finally
    LBody.Free;
  end;

  if ANotify then
    Exit;

  LRespLine := ReadLine(FResponseTimeoutMs);
  if Trim(LRespLine) = '' then
    Exit;

  LValue := TJSONObject.ParseJSONValue(LRespLine);
  if not (LValue is TJSONObject) then
  begin
    if Assigned(LValue) then
      LValue.Free;
    raise Exception.CreateFmt(
      'TMCPStdioClient: expected JSON object on %s, got: %s',
      [AMethod, Copy(LRespLine, 1, 200)]);
  end;
  Result := TJSONObject(LValue);

  // JSON-RPC error envelope -> exception (mirrors the HTTP client).
  LValue := Result.FindValue('error');
  if Assigned(LValue) and (LValue is TJSONObject) then
  begin
    LRespLine := Format('MCP %s error %d: %s',
      [AMethod,
       TJSONObject(LValue).GetValue<Integer>('code', 0),
       TJSONObject(LValue).GetValue<string>('message', '<no message>')]);
    Result.Free;
    raise Exception.Create(LRespLine);
  end;
end;

// ──────────────────────────────────────────────────────────────────────────
// MCP protocol method implementations
// ──────────────────────────────────────────────────────────────────────────

procedure TMCPStdioClient.Initialize;
var
  LParams, LCaps, LInfo, LResp: TJSONObject;
begin
  LParams := TJSONObject.Create;
  LParams.AddPair('protocolVersion', FProtocolVersion);

  LCaps := TJSONObject.Create;
  LParams.AddPair('capabilities', LCaps);

  LInfo := TJSONObject.Create;
  LInfo.AddPair('name',    FClientName);
  LInfo.AddPair('version', FClientVersion);
  LParams.AddPair('clientInfo', LInfo);

  LResp := RPC('initialize', LParams);
  if Assigned(LResp) then
    LResp.Free;

  // Notification: no id, no response.
  RPC('notifications/initialized', TJSONObject.Create, True);
  FInitialized := True;
end;

function TMCPStdioClient.ListTools: TJSONArray;
var
  LResp, LResult: TJSONObject;
  LArr: TJSONArray;
begin
  Result := nil;
  LResp := RPC('tools/list', TJSONObject.Create);
  try
    if not Assigned(LResp) then Exit;
    LResult := LResp.GetValue('result') as TJSONObject;
    if not Assigned(LResult) then Exit;
    LArr := LResult.GetValue('tools') as TJSONArray;
    if Assigned(LArr) then
      Result := LArr.Clone as TJSONArray;
  finally
    LResp.Free;
  end;
  if not Assigned(Result) then
    Result := TJSONArray.Create;
end;

function TMCPStdioClient.CallTool(const AName: string;
  AArguments: TJSONObject): string;
var
  LParams, LResp, LResult, LItem: TJSONObject;
  LContent: TJSONArray;
  LSB: TStringBuilder;
  I: Integer;
  LTextValue: TJSONValue;
begin
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
        if I > 0 then LSB.AppendLine;
        if not (LContent.Items[I] is TJSONObject) then
        begin
          LSB.Append(LContent.Items[I].ToJSON);
          Continue;
        end;
        LItem := TJSONObject(LContent.Items[I]);
        LTextValue := LItem.FindValue('text');
        if Assigned(LTextValue) and (LTextValue is TJSONString) then
          LSB.Append(TJSONString(LTextValue).Value)
        else
          LSB.Append(LItem.ToJSON);
      end;
      Result := LSB.ToString;
    finally
      LSB.Free;
    end;
  finally
    LResp.Free;
  end;
end;

function TMCPStdioClient.ListResources: TJSONArray;
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

function TMCPStdioClient.ListResourceTemplates: TJSONArray;
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

function TMCPStdioClient.ReadResource(const AURI: string;
  out AMimeType: string): string;
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

function TMCPStdioClient.ListPrompts: TJSONArray;
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

function TMCPStdioClient.GetPrompt(const AName: string;
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
