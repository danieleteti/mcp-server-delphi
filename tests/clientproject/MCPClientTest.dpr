// ***************************************************************************
//
// MCP Server for DMVCFramework - TMCPClient compliance test
//
// Copyright (c) 2010-2026 Daniele Teti
//
// https://github.com/danieleteti/delphimvcframework
//
// ***************************************************************************
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// Console smoke test for MVCFramework.MCP.Client.
//
// Requires the testproject MCP server running on the target URL (default
// http://localhost:8080/mcp). Mirrors the Python test_mcp_server.py
// structure: structured PASS/FAIL output, exit code 0 on full success and
// 1 on any failure. Suitable for CI.
//
// Usage:
//   MCPClientTest.exe [--url http://localhost:8080/mcp]
//
// ***************************************************************************

program MCPClientTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,  // expand TJSONArray.GetValue inline calls
  MVCFramework.MCP.Client,
  MVCFramework.MCP.Client.Stdio;

type
  TTestRunner = class
  private
    FPassed: Integer;
    FFailed: Integer;
    FErrors: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Ok(const AName: string);
    procedure Fail(const AName, AReason: string);
    procedure Section(const AName: string);
    function Summary: Boolean; // True if all passed
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
// Argument parsing
// ──────────────────────────────────────────────────────────────────────────

function ParseURL: string;
var
  I: Integer;
begin
  Result := 'http://localhost:8080/mcp';
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), '--url') and (I < ParamCount) then
    begin
      Result := ParamStr(I + 1);
      Exit;
    end;
end;

// Returns the stdio command (full command line) when --stdio-cmd is passed,
// or '' when not present. When set, the test runs over stdio against the
// supplied executable instead of HTTP.
function ParseStdioCmd: string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), '--stdio-cmd') and (I < ParamCount) then
    begin
      Result := ParamStr(I + 1);
      Exit;
    end;
end;

// ──────────────────────────────────────────────────────────────────────────
// Test cases
// ──────────────────────────────────────────────────────────────────────────

procedure TestInitialize(AClient: TMCPClientBase; AR: TTestRunner);
begin
  AR.Section('Initialize');
  try
    AClient.Initialize;
    // Session-id capture is HTTP-specific (transport header). For stdio
    // the handshake just has to not raise.
    if AClient is TMCPClient then
    begin
      if TMCPClient(AClient).SessionID <> '' then
        AR.Ok(Format('handshake → session %s...',
          [Copy(TMCPClient(AClient).SessionID, 1, 16)]))
      else
        AR.Fail('handshake', 'session id not captured from response header');
    end
    else
      AR.Ok('handshake (stdio) completed without raising');
  except
    on E: Exception do
      AR.Fail('handshake', E.ClassName + ': ' + E.Message);
  end;
end;

procedure TestTools(AClient: TMCPClientBase; AR: TTestRunner);
var
  LTools: TJSONArray;
  LTool: TJSONObject;
  I, LToolsWithSchema: Integer;
  LResult: string;
begin
  AR.Section('Tools');

  // ListTools
  LTools := nil;
  try
    LTools := AClient.ListTools;
    if LTools.Count > 0 then
      AR.Ok(Format('tools/list → %d tool(s)', [LTools.Count]))
    else
      AR.Fail('tools/list count', 'expected 1+, got 0');

    LToolsWithSchema := 0;
    for I := 0 to LTools.Count - 1 do
    begin
      if LTools.Items[I] is TJSONObject then
      begin
        LTool := TJSONObject(LTools.Items[I]);
        if Assigned(LTool.FindValue('name'))
          and Assigned(LTool.FindValue('description'))
          and Assigned(LTool.FindValue('inputSchema')) then
          Inc(LToolsWithSchema);
      end;
    end;
    if LToolsWithSchema = LTools.Count then
      AR.Ok('tools/list: every tool has name + description + inputSchema')
    else
      AR.Fail('tools/list shape',
        Format('%d/%d tools fully shaped', [LToolsWithSchema, LTools.Count]));
  except
    on E: Exception do
      AR.Fail('tools/list', E.ClassName + ': ' + E.Message);
  end;
  LTools.Free;

  // CallTool: reverse_string
  try
    LResult := AClient.CallTool('reverse_string',
      TJSONObject.Create.AddPair('Value', 'hello'));
    if LResult = 'olleh' then
      AR.Ok('tools/call reverse_string("hello") → "olleh"')
    else
      AR.Fail('reverse_string', Format('expected "olleh", got "%s"', [LResult]));
  except
    on E: Exception do
      AR.Fail('reverse_string', E.ClassName + ': ' + E.Message);
  end;

  // CallTool: add_integers
  try
    LResult := AClient.CallTool('add_integers',
      TJSONObject.Create
        .AddPair('A', TJSONNumber.Create(3))
        .AddPair('B', TJSONNumber.Create(7)));
    if LResult = '10' then
      AR.Ok('tools/call add_integers(3, 7) → "10"')
    else
      AR.Fail('add_integers', Format('expected "10", got "%s"', [LResult]));
  except
    on E: Exception do
      AR.Fail('add_integers', E.ClassName + ': ' + E.Message);
  end;

  // CallTool: always_fail (server returns isError, client returns text)
  try
    LResult := AClient.CallTool('always_fail',
      TJSONObject.Create.AddPair('Message', 'simulated failure'));
    if Pos('simulated failure', LResult) > 0 then
      AR.Ok('tools/call always_fail propagates server error message')
    else
      AR.Fail('always_fail',
        Format('expected message in result, got "%s"', [LResult]));
  except
    on E: Exception do
      AR.Fail('always_fail', E.ClassName + ': ' + E.Message);
  end;
end;

procedure TestResources(AClient: TMCPClientBase; AR: TTestRunner);
var
  LRes: TJSONArray;
  LMime, LText: string;
  LObj: TJSONValue;
begin
  AR.Section('Resources');

  // ListResources
  LRes := nil;
  try
    LRes := AClient.ListResources;
    if LRes.Count >= 3 then
      AR.Ok(Format('resources/list → %d resource(s)', [LRes.Count]))
    else
      AR.Fail('resources/list count',
        Format('expected 3+, got %d', [LRes.Count]));
  except
    on E: Exception do
      AR.Fail('resources/list', E.ClassName + ': ' + E.Message);
  end;
  LRes.Free;

  // ReadResource: static text
  try
    LText := AClient.ReadResource('config://app/settings', LMime);
    LObj := TJSONObject.ParseJSONValue(LText);
    try
      if Assigned(LObj) and (LObj is TJSONObject) then
        AR.Ok('resources/read config://app/settings → valid JSON')
      else
        AR.Fail('resources/read app/settings', 'body is not a JSON object');
    finally
      LObj.Free;
    end;
    if LMime = 'application/json' then
      AR.Ok('resources/read app/settings: mimeType captured (application/json)')
    else
      AR.Fail('resources/read app/settings mimeType',
        Format('expected application/json, got "%s"', [LMime]));
  except
    on E: Exception do
      AR.Fail('resources/read app/settings', E.ClassName + ': ' + E.Message);
  end;

  // ReadResource: blob (logo.png) — should yield a "(blob, N base64 chars)"
  // textual placeholder, not raise.
  try
    LText := AClient.ReadResource('file:///assets/logo.png', LMime);
    if Pos('blob', LText) > 0 then
      AR.Ok('resources/read blob → placeholder string')
    else
      AR.Fail('resources/read blob',
        Format('expected blob placeholder, got "%s"',
          [Copy(LText, 1, 60)]));
  except
    on E: Exception do
      AR.Fail('resources/read blob', E.ClassName + ': ' + E.Message);
  end;
end;

procedure TestResourceTemplates(AClient: TMCPClientBase; AR: TTestRunner);
var
  LTpls: TJSONArray;
  LMime, LText: string;
  LObj: TJSONValue;
  LJ: TJSONObject;
  LIdVal: TJSONValue;
begin
  AR.Section('Resource Templates');

  // ListResourceTemplates — testproject registers 2: user://{id}, weather://forecast/{city}/{date}
  LTpls := nil;
  try
    LTpls := AClient.ListResourceTemplates;
    if LTpls.Count >= 2 then
      AR.Ok(Format('resources/templates/list → %d template(s)', [LTpls.Count]))
    else
      AR.Fail('resources/templates/list count',
        Format('expected 2+, got %d', [LTpls.Count]));
  except
    on E: Exception do
      AR.Fail('resources/templates/list', E.ClassName + ': ' + E.Message);
  end;
  LTpls.Free;

  // ReadResource: single-variable template
  try
    LText := AClient.ReadResource('user://42', LMime);
    LObj := TJSONObject.ParseJSONValue(LText);
    try
      if Assigned(LObj) and (LObj is TJSONObject) then
      begin
        LJ := TJSONObject(LObj);
        LIdVal := LJ.FindValue('id');
        if Assigned(LIdVal) and (LIdVal is TJSONString)
           and (TJSONString(LIdVal).Value = '42') then
          AR.Ok('templated read user://42 → id=42 in body')
        else
          AR.Fail('templated read user://42',
            'id field missing or not "42" in returned JSON');
      end
      else
        AR.Fail('templated read user://42', 'body is not a JSON object');
    finally
      LObj.Free;
    end;
  except
    on E: Exception do
      AR.Fail('templated read user://42', E.ClassName + ': ' + E.Message);
  end;

  // ReadResource: multi-variable template
  try
    LText := AClient.ReadResource('weather://forecast/Rome/2026-05-08', LMime);
    LObj := TJSONObject.ParseJSONValue(LText);
    try
      if Assigned(LObj) and (LObj is TJSONObject) then
      begin
        LJ := TJSONObject(LObj);
        if (LJ.GetValue<string>('city', '') = 'Rome')
           and (LJ.GetValue<string>('date', '') = '2026-05-08') then
          AR.Ok('templated read weather forecast → city/date bound correctly')
        else
          AR.Fail('templated read multi-var',
            'expected city=Rome, date=2026-05-08 in body');
      end
      else
        AR.Fail('templated read multi-var', 'body is not a JSON object');
    finally
      LObj.Free;
    end;
  except
    on E: Exception do
      AR.Fail('templated read multi-var', E.ClassName + ': ' + E.Message);
  end;

  // Reading the literal template URI must error on the server side.
  try
    LText := AClient.ReadResource('user://{id}', LMime);
    AR.Fail('literal template URI rejected',
      'expected exception, got "' + Copy(LText, 1, 60) + '"');
  except
    on E: Exception do
      AR.Ok('literal template URI rejected (server raised: '
        + Copy(E.Message, 1, 60) + ')');
  end;
end;

procedure TestBridge(AClient: TMCPClientBase; AR: TTestRunner);
var
  LResult: string;
  LObj: TJSONValue;
  LJO: TJSONObject;
begin
  AR.Section('Bridge (proxy tools)');

  // GET /bridge-test — no params
  try
    LResult := AClient.CallTool('get_bridge-test', TJSONObject.Create);
    LObj := TJSONObject.ParseJSONValue(LResult);
    try
      if Assigned(LObj) and (LObj is TJSONObject) then
        AR.Ok('bridge get_bridge-test → JSON response')
      else
        AR.Fail('get_bridge-test', 'expected JSON, got: ' + Copy(LResult, 1, 60));
    finally
      LObj.Free;
    end;
  except
    on E: Exception do
      AR.Fail('get_bridge-test', E.ClassName + ': ' + E.Message);
  end;

  // GET /bridge-test/($name) — path param
  try
    LResult := AClient.CallTool('get_bridge-test_by_name',
      TJSONObject.Create.AddPair('name', 'World'));
    if Pos('World', LResult) > 0 then
      AR.Ok('bridge get_bridge-test_by_name → greeting for "World"')
    else
      AR.Fail('get_bridge-test_by_name',
        'expected "World" in response, got: ' + Copy(LResult, 1, 60));
  except
    on E: Exception do
      AR.Fail('get_bridge-test_by_name', E.ClassName + ': ' + E.Message);
  end;

  // GET /bridge-test/search?q=foo&limit=3 — query params
  try
    LResult := AClient.CallTool('get_bridge-test_search',
      TJSONObject.Create
        .AddPair('q', 'foo')
        .AddPair('limit', TJSONNumber.Create(3)));
    LObj := TJSONObject.ParseJSONValue(LResult);
    try
      if Assigned(LObj) and (LObj is TJSONObject) then
      begin
        LJO := TJSONObject(LObj);
        if (LJO.GetValue<string>('q', '') = 'foo') and
           (LJO.GetValue<Integer>('limit', 0) = 3) then
          AR.Ok('bridge get_bridge-test_search → q and limit reflected')
        else
          AR.Fail('get_bridge-test_search',
            'q/limit not reflected; got: ' + Copy(LResult, 1, 80));
      end
      else
        AR.Fail('get_bridge-test_search',
          'expected JSON, got: ' + Copy(LResult, 1, 60));
    finally
      LObj.Free;
    end;
  except
    on E: Exception do
      AR.Fail('get_bridge-test_search', E.ClassName + ': ' + E.Message);
  end;

  // POST /bridge-test/echo — body param
  try
    LResult := AClient.CallTool('post_bridge-test_echo',
      TJSONObject.Create.AddPair('body', '{"echo":true}'));
    if Pos('echo', LResult) > 0 then
      AR.Ok('bridge post_bridge-test_echo → body echoed')
    else
      AR.Fail('post_bridge-test_echo',
        'expected echo in response, got: ' + Copy(LResult, 1, 60));
  except
    on E: Exception do
      AR.Fail('post_bridge-test_echo', E.ClassName + ': ' + E.Message);
  end;
end;

procedure TestPrompts(AClient: TMCPClientBase; AR: TTestRunner);
var
  LPrompts, LMessages: TJSONArray;
  LArgs: TJSONObject;
  LMsg: TJSONObject;
  LRoleVal: TJSONValue;
begin
  AR.Section('Prompts');

  // ListPrompts
  LPrompts := nil;
  try
    LPrompts := AClient.ListPrompts;
    if LPrompts.Count >= 3 then
      AR.Ok(Format('prompts/list → %d prompt(s)', [LPrompts.Count]))
    else
      AR.Fail('prompts/list count',
        Format('expected 3+, got %d', [LPrompts.Count]));
  except
    on E: Exception do
      AR.Fail('prompts/list', E.ClassName + ': ' + E.Message);
  end;
  LPrompts.Free;

  // GetPrompt: code_review (testproject prompt with required arg `code`)
  LMessages := nil;
  try
    LArgs := TJSONObject.Create;
    LArgs.AddPair('code', 'function add(a, b) { return a + b; }');
    LArgs.AddPair('language', 'JavaScript');
    LMessages := AClient.GetPrompt('code_review', LArgs);

    if LMessages.Count >= 2 then
      AR.Ok(Format('prompts/get code_review → %d message(s)', [LMessages.Count]))
    else
      AR.Fail('prompts/get code_review messages',
        Format('expected 2+, got %d', [LMessages.Count]));

    if (LMessages.Count > 0) and (LMessages.Items[0] is TJSONObject) then
    begin
      LMsg := TJSONObject(LMessages.Items[0]);
      LRoleVal := LMsg.FindValue('role');
      if Assigned(LRoleVal) and (LRoleVal is TJSONString) then
        AR.Ok('prompts/get message[0] has role="'
          + TJSONString(LRoleVal).Value + '"')
      else
        AR.Fail('prompts/get message shape', 'message[0] missing role');
    end;
  except
    on E: Exception do
      AR.Fail('prompts/get code_review', E.ClassName + ': ' + E.Message);
  end;
  LMessages.Free;
end;

// ──────────────────────────────────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────────────────────────────────

var
  LURL, LStdioCmd: string;
  LClient: TMCPClientBase;
  LR: TTestRunner;
  LSuccess, LCanRun: Boolean;
begin
  ReportMemoryLeaksOnShutdown := True;
  LStdioCmd := ParseStdioCmd;

  WriteLn('TMCPClient compliance test');
  if LStdioCmd <> '' then
  begin
    WriteLn('Transport: stdio');
    WriteLn('Command  : ', LStdioCmd);
    LClient := TMCPStdioClient.Create(LStdioCmd);
  end
  else
  begin
    LURL := ParseURL;
    WriteLn('Transport: HTTP');
    WriteLn('Target   : ', LURL);
    LClient := TMCPClient.Create(LURL);
  end;
  WriteLn(StringOfChar('=', 60));

  LR := TTestRunner.Create;
  try
    LClient.ClientName := 'TMCPClientTest';
    try
      TestInitialize(LClient, LR);

      // For HTTP we gate the remaining tests on a captured session.
      // For stdio we just check Initialize did not raise (LR.Failed unchanged).
      if LClient is TMCPClient then
        LCanRun := TMCPClient(LClient).SessionID <> ''
      else
        LCanRun := LR.Failed = 0;

      if LCanRun then
      begin
        TestTools(LClient, LR);
        TestResources(LClient, LR);
        TestResourceTemplates(LClient, LR);
        TestPrompts(LClient, LR);
        TestBridge(LClient, LR);
      end
      else
        WriteLn('FATAL: handshake failed, skipping remaining tests');
    except
      on E: Exception do
      begin
        WriteLn('UNEXPECTED EXCEPTION: ', E.ClassName, ': ', E.Message);
        LR.Fail('top-level', E.Message);
      end;
    end;

    LSuccess := LR.Summary;
    if LSuccess then
      ExitCode := 0
    else
      ExitCode := 1;
  finally
    LClient.Free;
    LR.Free;
  end;
end.
