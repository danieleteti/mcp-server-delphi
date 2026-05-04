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
//   4. Reads user prompts from the console and prints the agent's answers
//
// This is the "host + client" half of the MCP demo: the AI client spawns
// and consumes a local MCP server, exactly like Claude Desktop does. The
// only difference is that here YOU write the agent logic in Delphi
// instead of using a closed-source GUI client.
//
// CONFIGURATION (bin/.env)
//   agent.api_key=<your-openai-or-openrouter-key>
//   agent.llm_base_url=https://api.openai.com/v1
//                       (or https://openrouter.ai/api/v1, etc.)
//   agent.model=gpt-4o-mini
//                       (or anthropic/claude-haiku-4-5 on OpenRouter, etc.)
//   mcp.command=..\..\quickstart_stdio\bin\QuickStartStdio.exe
//                       (full command line for the stdio server, including
//                        any args; relative paths resolve against this
//                        executable's folder)
//   agent.max_turns=25
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
  MVCFramework.Commons,
  MVCFramework.MCP.Client,
  MVCFramework.MCP.Client.Stdio,
  MVCFramework.MCP.OpenAIAgent;

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

procedure ReplLoop(AAgent: TMCPOpenAIAgent);
var
  LMessages: TJSONArray;
  LUser: string;
  LResult: TMCPAgentResult;
  LMsg: TJSONObject;
begin
  LMessages := TJSONArray.Create;
  try
    WriteLn('Type a message and press Enter. Empty line or /quit to exit.');
    WriteLn;
    while True do
    begin
      Write('> ');
      ReadLn(LUser);
      LUser := Trim(LUser);
      if (LUser = '') or SameText(LUser, '/quit') or SameText(LUser, '/exit') then
        Break;

      LMsg := TJSONObject.Create;
      LMsg.AddPair('role', 'user');
      LMsg.AddPair('content', LUser);
      LMessages.AddElement(LMsg);

      try
        LResult := AAgent.Run(LMessages);
      except
        on E: Exception do
        begin
          WriteLn('[error] ', E.ClassName, ': ', E.Message);
          // Drop the last user message so the next turn starts clean.
          LMessages.Remove(LMessages.Count - 1).Free;
          Continue;
        end;
      end;

      // Append the assistant message to the conversation so multi-turn
      // context is preserved.
      LMsg := TJSONObject.Create;
      LMsg.AddPair('role', 'assistant');
      LMsg.AddPair('content', LResult.Content);
      LMessages.AddElement(LMsg);

      WriteLn;
      WriteLn(LResult.Content);
      WriteLn;
      WriteLn(Format('  [tools used: %d, tokens: %d]',
        [LResult.ToolCallCount, LResult.TotalTokens]));
      WriteLn;
    end;
  finally
    LMessages.Free;
  end;
end;

var
  LCommand: string;
  LStdioClient: TMCPStdioClient;
  LAgent: TMCPOpenAIAgent;
begin
  try
    LCommand := dotEnv.Env('mcp.command',
      '..\..\quickstart_stdio\bin\QuickStartStdio.exe');
    LCommand := ResolveCommandLine(LCommand);

    WriteLn('=== MCP Stdio Agent (Quick Start) ===');
    WriteLn('Spawning MCP server: ', LCommand);
    WriteLn;

    LStdioClient := TMCPStdioClient.Create(LCommand);
    try
      LStdioClient.ClientName := 'QuickStartStdioAgent';

      LAgent := TMCPOpenAIAgent.Create(
        '',  // FMCPURL unused — we inject the client below
        dotEnv.Env('agent.api_key',     ''),
        dotEnv.Env('agent.model',       'gpt-4o-mini'),
        dotEnv.Env('agent.llm_base_url','https://api.openai.com/v1'));
      try
        LAgent.MaxTurns := dotEnv.Env('agent.max_turns', 25);
        LAgent.SystemPrompt := BuildSystemPrompt;
        LAgent.SetMCPClient(LStdioClient, False); // we own the client below

        if LAgent.APIKey = '' then
        begin
          WriteLn('ERROR: agent.api_key not set in bin\.env. Aborting.');
          ExitCode := 2;
          Exit;
        end;

        ReplLoop(LAgent);
      finally
        LAgent.Free;
      end;
    finally
      LStdioClient.Free; // closes pipes + waits for child to exit
    end;

    WriteLn('Bye.');
  except
    on E: Exception do
    begin
      WriteLn('FATAL: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
