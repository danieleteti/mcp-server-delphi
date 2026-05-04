// ***************************************************************************
//
// MCP Server for DMVCFramework - Quick Start (stdio agent)
//
// Copyright (c) 2010-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// QUICK START - STDIO AGENT
// =========================
// A minimal Delphi console agent that:
//   1. Spawns an MCP server over stdio (by default the bundled
//      quickstart_stdio.exe, configurable via .env)
//   2. Talks to it through TMCPStdioClient (anonymous pipes, line-delimited
//      JSON-RPC)
//   3. Drives a TMCPOpenAIAgent loop against an OpenAI-compatible LLM
//   4. Reads user prompts from a small TUI built on MVCFramework.Console
//
// This is the "host + client" half of the MCP demo: the AI client spawns
// and consumes a local MCP server, exactly like Claude Desktop does. The
// only difference is that here YOU write the agent logic in Delphi
// instead of using a closed-source GUI client.
//
// CONFIGURATION (bin/.env)
//   agent.api_key=<your-openai-or-openrouter-key>
//   agent.llm_base_url=https://api.openai.com/v1
//   agent.model=gpt-4o-mini
//   mcp.command=..\..\quickstart_stdio\bin\QuickStartStdio.exe
//   agent.max_turns=25
//   logger.config.file=loggerpro.json   (optional, default loggerpro.json)
//
// USAGE
//   QuickStartStdioAgent.exe
//   > Hello
//   <agent reply>
//   > /quit         (or empty line, Ctrl+C)
//
// ***************************************************************************

program QuickStartStdioAgent;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,
  System.IOUtils,
  System.StrUtils,
  LoggerPro,
  LoggerPro.Config,
  LoggerPro.Builder,
  MVCFramework.DotEnv,
  MVCFramework.Commons,
  MVCFramework.Logger,
  MVCFramework.Console,
  MVCFramework.MCP.Client,
  MVCFramework.MCP.Client.Stdio,
  MVCFramework.MCP.OpenAIAgent;

// Reusable inline-ANSI styles. RESET prevents colour bleed.
const
  BADGE_OK   = Fore.White + Back.DarkGreen;
  BADGE_FAIL = Fore.White + Back.DarkRed;
  BADGE_INFO = Fore.White + Back.DarkBlue;
  RESET      = Style.ResetAll;
  MUTED      = Fore.DarkGray;
  PROMPT_FG  = Style.Bright + Fore.Cyan;
  BOX_WIDTH  = 78;

// ──────────────────────────────────────────────────────────────────────────
// Bootstrap: dotEnv + LoggerPro
//
// Configure the logger BEFORE any LogX call (and any dotEnv auto-init) so
// the default console appender never gets installed. Without this, the
// dotEnv bootstrap emits "[INFO] Initializing default dotEnv instance"
// straight onto the TUI surface and breaks every box / spinner / colour.
// ──────────────────────────────────────────────────────────────────────────

procedure Bootstrap;
var
  LConfigFile: string;
  LBuilder: ILoggerProBuilder;
begin
  EnableUTF8Console;        // Windows: CP 65001 so box-drawing chars render
  EnableANSIColorConsole;   // Windows 10+: enable virtual-terminal ANSI escapes

  // Configure dotEnv WITHOUT a logger callback so its bootstrap doesn't
  // trigger LoggerPro's default (console) appender.
  dotEnvConfigure(
    function: IMVCDotEnv
    begin
      Result := NewDotEnv
        .UseStrategy(TMVCDotEnvPriority.FileThenEnv)
        .UseProfile('test')
        .UseProfile('prod')
        .Build(AppPath);
    end);

  // Resolve the LoggerPro JSON config against AppPath so launching the
  // agent from a different cwd still finds it.
  LConfigFile := dotEnv.Env('logger.config.file', 'loggerpro.json');
  if not TPath.IsPathRooted(LConfigFile) then
    LConfigFile := TPath.Combine(AppPath, LConfigFile);

  if TFile.Exists(LConfigFile) then
  begin
    LBuilder := TLoggerProConfig.BuilderFromJSONFile(LConfigFile);
    SetDefaultLogger(LBuilder.Build);
  end
  else
  begin
    // Fallback: silent logger (no appenders). Keeps the console pristine
    // even when the JSON config is not deployed alongside the exe.
    SetDefaultLogger(LoggerProBuilder.Build);
  end;
end;

// ──────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────

function ResolveCommandLine(const ARaw: string): string;
var
  LExePath, LFirstToken, LRest: string;
  LSpace: Integer;
begin
  // Split on first space: <executable> <rest-of-args>. If the executable
  // path is relative, resolve it against this exe's folder so the example
  // works no matter where the agent is launched from.
  LSpace := Pos(' ', ARaw);
  if LSpace = 0 then
  begin
    LFirstToken := ARaw;
    LRest := '';
  end
  else
  begin
    LFirstToken := Copy(ARaw, 1, LSpace - 1);
    LRest := Copy(ARaw, LSpace + 1, MaxInt);
  end;

  if (LFirstToken <> '') and not TPath.IsPathRooted(LFirstToken) then
  begin
    LExePath := TPath.GetDirectoryName(ParamStr(0));
    LFirstToken := TPath.Combine(LExePath, LFirstToken);
    LFirstToken := TPath.GetFullPath(LFirstToken);
  end;

  if LRest = '' then
    Result := LFirstToken
  else
    Result := LFirstToken + ' ' + LRest;
end;

function BuildSystemPrompt: string;
begin
  Result :=
    'You are a helpful Delphi-powered AI assistant.' + sLineBreak +
    'You can call MCP tools exposed by the local stdio server to help the user.' + sLineBreak +
    'Always invoke the appropriate tool before answering questions about live data.' + sLineBreak +
    'Reply concisely.';
end;

// ──────────────────────────────────────────────────────────────────────────
// TUI (powered by MVCFramework.Console)
// ──────────────────────────────────────────────────────────────────────────

procedure DrawHeader;
begin
  // ClrScr (and most console calls) raise on redirected stdout/stdin
  // (typical of CI pipes and smoke tests). We tolerate that: in a real
  // interactive terminal this still resets the screen as expected, in a
  // pipe it just continues without the cosmetic clear.
  try ClrScr; except end;
  WriteHeader('MCP Stdio Agent  -  Quick Start', BOX_WIDTH, Cyan);
  WriteLn;
  WriteLine(
    '  Delphi-side AI agent that spawns and consumes a stdio MCP server',
    Gray);
  WriteLine(
    '  through TMCPStdioClient. Powered by mcp-server-delphi / DMVCFramework.',
    Gray);
  WriteLn;
end;

// CI-step style status line: green " OK " badge + message.
procedure StatusOk(const AMessage: string);
begin
  WriteLn(BADGE_OK + '  OK  ' + RESET + '  ' + AMessage);
end;

procedure StatusInfo(const AMessage: string);
begin
  WriteLn(BADGE_INFO + ' INFO ' + RESET + '  ' + AMessage);
end;

procedure DrawSetupSummary(const AServerCmd: string; AToolCount: Integer;
  const AModel, ABaseURL: string);
begin
  StatusOk('MCP server spawned: ' + AServerCmd);
  StatusOk(Format('handshake complete - %d tool(s) available', [AToolCount]));
  StatusOk(Format('LLM: %s @ %s', [AModel, ABaseURL]));
  WriteLn;
end;

procedure DrawTips;
var
  LTips: TStringArray;
begin
  SetLength(LTips, 3);
  LTips[0] := 'Type a question and press Enter';
  LTips[1] := 'The agent calls MCP tools as needed and replies';
  LTips[2] := 'Empty line or /quit to exit';
  WriteFormattedList('Tips:', LTips, lsArrow);
  WriteLn;
end;

// Hard-wraps a multi-line string at AMaxWidth, splitting on word boundaries
// and preserving blank lines. Box() renders one input string per row and
// does NOT word-wrap; if a line is wider than the inner box width the
// right border is pushed off-screen and subsequent rows desync. Always
// pre-wrap LLM output (which can produce long markdown lines) before
// handing it to Box.
function WrapLines(const AText: string; AMaxWidth: Integer): TStringArray;
var
  LParagraphs: TArray<string>;
  LBuf: TList<string>;
  LWords: TArray<string>;
  LCurrent, LWord: string;
  I: Integer;
  LLine: string;
begin
  if AMaxWidth < 8 then
    AMaxWidth := 8;
  LParagraphs := AText.Split([sLineBreak]);
  LBuf := TList<string>.Create;
  try
    for LLine in LParagraphs do
    begin
      if Length(LLine) <= AMaxWidth then
      begin
        LBuf.Add(LLine);
        Continue;
      end;
      // Split on spaces and re-flow word by word.
      LWords := LLine.Split([' ']);
      LCurrent := '';
      for I := 0 to High(LWords) do
      begin
        LWord := LWords[I];
        // A single word longer than the budget gets force-broken so
        // the box never overflows.
        while Length(LWord) > AMaxWidth do
        begin
          if LCurrent <> '' then
          begin
            LBuf.Add(LCurrent);
            LCurrent := '';
          end;
          LBuf.Add(Copy(LWord, 1, AMaxWidth));
          LWord := Copy(LWord, AMaxWidth + 1, MaxInt);
        end;
        if LCurrent = '' then
          LCurrent := LWord
        else if Length(LCurrent) + 1 + Length(LWord) <= AMaxWidth then
          LCurrent := LCurrent + ' ' + LWord
        else
        begin
          LBuf.Add(LCurrent);
          LCurrent := LWord;
        end;
      end;
      if LCurrent <> '' then
        LBuf.Add(LCurrent);
    end;
    // TStringArray (MVCFramework.Console) is a distinct type from
    // TArray<string>; copy element-by-element instead of returning
    // LBuf.ToArray (which would be a TArray<string>).
    SetLength(Result, LBuf.Count);
    for I := 0 to LBuf.Count - 1 do
      Result[I] := LBuf[I];
  finally
    LBuf.Free;
  end;
end;

procedure DrawAssistantReply(const AContent: string;
  AToolCount, APromptTokens, ACompletionTokens, ATotalTokens: Integer);
var
  LSA: TStringArray;
begin
  WriteLn;
  if Trim(AContent) = '' then
    LSA := ['(empty reply)']
  else
    // BOX_WIDTH is the total box width; subtract 4 for the two borders +
    // the one-space inner padding on each side that Box() inserts.
    LSA := WrapLines(AContent, BOX_WIDTH - 4);
  Box('Assistant', LSA, BOX_WIDTH);
  WriteLn(MUTED +
    Format('  tools: %d   tokens: %d (prompt %d, completion %d)',
      [AToolCount, ATotalTokens, APromptTokens, ACompletionTokens]) + RESET);
  WriteLn;
end;

// ──────────────────────────────────────────────────────────────────────────
// REPL
// ──────────────────────────────────────────────────────────────────────────

procedure ReplLoop(AAgent: TMCPOpenAIAgent);
var
  LMessages: TJSONArray;
  LUser: string;
  LResult: TMCPAgentResult;
  LMsg: TJSONObject;
  LSpinner: ISpinner;
begin
  LMessages := TJSONArray.Create;
  try
    while True do
    begin
      // PROMPT: bright cyan ">" then reset before reading user input so
      // typing renders in the default console colour.
      Write(PROMPT_FG + '> ' + RESET);
      Flush(Output);
      ReadLn(LUser);
      LUser := Trim(LUser);
      if (LUser = '') or SameText(LUser, '/quit') or SameText(LUser, '/exit') then
        Break;

      LMsg := TJSONObject.Create;
      LMsg.AddPair('role', 'user');
      LMsg.AddPair('content', LUser);
      LMessages.AddElement(LMsg);

      // Spinner pattern from MVCFramework.Console's BlogPostShowcase:
      //   * Flush before Spinner so GetCursorPosition reads the committed column
      //   * HideCursor while it animates
      //   * ShowCursor + S.Hide on completion (Hide also clears the label)
      Flush(Output);
      HideCursor;
      LSpinner := Spinner('thinking...', ssDots, DarkGray);
      try
        try
          LResult := AAgent.Run(LMessages);
        except
          on E: Exception do
          begin
            LSpinner.Hide;
            LSpinner := nil;
            ShowCursor;
            WriteLn;
            WriteError(E.ClassName + ': ' + E.Message);
            WriteLn;
            // Drop the last user message so the next turn starts clean.
            LMessages.Remove(LMessages.Count - 1).Free;
            Continue;
          end;
        end;
      finally
        if Assigned(LSpinner) then
        begin
          LSpinner.Hide;
          LSpinner := nil;
        end;
        ShowCursor;
      end;

      // Append the assistant message so multi-turn context is preserved.
      LMsg := TJSONObject.Create;
      LMsg.AddPair('role', 'assistant');
      LMsg.AddPair('content', LResult.Content);
      LMessages.AddElement(LMsg);

      DrawAssistantReply(LResult.Content,
        LResult.ToolCallCount,
        LResult.PromptTokens,
        LResult.CompletionTokens,
        LResult.TotalTokens);
    end;
  finally
    LMessages.Free;
  end;
end;

// ──────────────────────────────────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────────────────────────────────

var
  LCommand, LModel, LBaseURL: string;
  LStdioClient: TMCPStdioClient;
  LAgent: TMCPOpenAIAgent;
  LTools: TJSONArray;
  LToolCount: Integer;
begin
  try
    Bootstrap;
    DrawHeader;

    LCommand := dotEnv.Env('mcp.command',
      '..\..\quickstart_stdio\bin\QuickStartStdio.exe');
    LCommand := ResolveCommandLine(LCommand);
    LModel   := dotEnv.Env('agent.model',        'gpt-4o-mini');
    LBaseURL := dotEnv.Env('agent.llm_base_url', 'https://api.openai.com/v1');

    if dotEnv.Env('agent.api_key', '') = '' then
    begin
      WriteError('agent.api_key not set in bin\.env. Aborting.');
      WriteLn;
      StatusInfo('Copy bin\.env.example to bin\.env and add your LLM key.');
      ExitCode := 2;
      Exit;
    end;

    LStdioClient := TMCPStdioClient.Create(LCommand);
    try
      LStdioClient.ClientName := 'QuickStartStdioAgent';

      // Eager handshake + tool discovery so we can report tool count BEFORE
      // the first user prompt — fails loud and early if the server is broken.
      LStdioClient.Initialize;
      LTools := LStdioClient.ListTools;
      try
        LToolCount := LTools.Count;
      finally
        LTools.Free;
      end;

      DrawSetupSummary(LCommand, LToolCount, LModel, LBaseURL);
      DrawTips;

      LAgent := TMCPOpenAIAgent.Create(
        '',  // FMCPURL unused - we inject the client below
        dotEnv.Env('agent.api_key', ''),
        LModel,
        LBaseURL);
      try
        LAgent.MaxTurns := dotEnv.Env('agent.max_turns', 25);
        LAgent.SystemPrompt := BuildSystemPrompt;
        LAgent.SetMCPClient(LStdioClient, False); // we own the client below
        ReplLoop(LAgent);
      finally
        LAgent.Free;
      end;
    finally
      LStdioClient.Free; // closes pipes + waits for child to exit
    end;

    WriteLn;
    StatusInfo('Bye.');
  except
    on E: Exception do
    begin
      WriteLn;
      ShowCursor; // make sure we never leave the cursor hidden on crash
      WriteError(E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
