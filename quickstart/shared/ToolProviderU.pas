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
// TOOL PROVIDER
// =============
// Tools are functions that AI assistants can call. They are the "actions"
// your server can perform: query a database, call an API, run a calculation,
// transform data, etc.
//
// HOW TO ADD A NEW TOOL:
//   1. Add a public method to TMyTools (or create a new TMCPToolProvider class)
//   2. Decorate it with [MCPTool('tool_name', 'Description for the AI')]
//   3. Decorate each parameter with [MCPParam('Description')]
//   4. Return a TMCPToolResult (see factory methods below)
//   5. That's it! The MCP library discovers the tool via RTTI automatically
//
// SUPPORTED PARAMETER TYPES:
//   string, Integer, Int64, Double, Boolean
//   The library auto-generates the JSON Schema for the AI client.
//
// OPTIONAL PARAMETERS:
//   Use [MCPParam('Description', False)] to mark a parameter as optional.
//   Optional parameters receive their default value when the AI doesn't
//   provide them (empty string, 0, 0.0, False).
//
// RESULT FACTORY METHODS (most common):
//   TMCPToolResult.Text('...')                 --> plain text response
//   TMCPToolResult.Error('...')                --> error (isError=true)
//   TMCPToolResult.FromValue(123)              --> Integer, Double, or Boolean
//   TMCPToolResult.JSON(AJsonObject)           --> serialized JSON object
//   TMCPToolResult.FromObject(AObject)         --> auto-serialize a TObject
//   TMCPToolResult.FromCollection(AList)       --> auto-serialize a TObjectList
//   TMCPToolResult.FromDataSet(ADataSet)       --> auto-serialize a TDataSet
//   TMCPToolResult.Image(ABase64, AMimeType)   --> image content
//   TMCPToolResult.Audio(ABase64, AMimeType)   --> audio content
//
// MULTI-CONTENT (FLUENT API):
//   TMCPToolResult.Text('Summary')
//     .AddImage(LChartBase64, 'image/png')
//     .AddResource('file:///data.csv', LCsv, 'text/csv');
//
// ***************************************************************************

unit ToolProviderU;

interface

uses
  MVCFramework.MCP.ToolProvider,
  MVCFramework.MCP.Attributes;

type
  // -------------------------------------------------------------------------
  // TMyTools - Your MCP tool provider
  //
  // Add, modify, or remove methods below to define the tools your AI clients
  // can use. Each public method decorated with [MCPTool] becomes a callable
  // tool in the MCP protocol.
  // -------------------------------------------------------------------------
  TMyTools = class(TMCPToolProvider)
  public

    // A simple tool that reverses a string.
    // The AI sees: name="reverse_string", description="Reverses a string"
    // with one required parameter "Value" of type string.
    [MCPTool('reverse_string', 'Reverses a string')]
    function ReverseString(
      [MCPParam('The string to reverse')] const Value: string
    ): TMCPToolResult;

    // A tool with two required parameters.
    // Parameter types (Double) are auto-detected from the Delphi signature.
    [MCPTool('add_numbers', 'Adds two numbers and returns the sum')]
    function AddNumbers(
      [MCPParam('First number')] const A: Double;
      [MCPParam('Second number')] const B: Double
    ): TMCPToolResult;

    // A tool that demonstrates error handling.
    // When B=0, it returns TMCPToolResult.Error(...) which tells the AI
    // that the operation failed (isError=true in the MCP response).
    [MCPTool('divide', 'Divides A by B, returns error on division by zero')]
    function Divide(
      [MCPParam('Dividend')] const A: Double;
      [MCPParam('Divisor (must not be zero)')] const B: Double
    ): TMCPToolResult;

    // A tool with an OPTIONAL parameter.
    // The second argument of MCPParam controls whether the parameter is
    // required (True, default) or optional (False).
    // When the AI omits "Separator", Delphi receives an empty string.
    [MCPTool('concat_strings', 'Concatenates two strings with a separator')]
    function ConcatStrings(
      [MCPParam('First string')] const A: string;
      [MCPParam('Second string')] const B: string;
      [MCPParam('Separator between strings (default: space)', False)] const Separator: string
    ): TMCPToolResult;

    // A tool that returns a Boolean result.
    // TMCPToolResult.FromValue() handles Integer, Int64, Double, and Boolean.
    [MCPTool('is_palindrome', 'Checks if a string is a palindrome')]
    function IsPalindrome(
      [MCPParam('The string to check')] const Value: string
    ): TMCPToolResult;

  end;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  MVCFramework.MCP.Server;

{ TMyTools }

function TMyTools.ReverseString(const Value: string): TMCPToolResult;
begin
  // TMCPToolResult.Text() returns a simple text response
  Result := TMCPToolResult.Text(System.StrUtils.ReverseString(Value));
end;

function TMyTools.AddNumbers(const A, B: Double): TMCPToolResult;
begin
  // TMCPToolResult.FromValue() converts scalars to text
  Result := TMCPToolResult.FromValue(A + B);
end;

function TMyTools.Divide(const A, B: Double): TMCPToolResult;
begin
  if B = 0 then
    // TMCPToolResult.Error() returns isError=true in the MCP response.
    // The AI will know the operation failed and can explain why to the user.
    Result := TMCPToolResult.Error('Division by zero is not allowed')
  else
    Result := TMCPToolResult.FromValue(A / B);
end;

function TMyTools.ConcatStrings(const A, B, Separator: string): TMCPToolResult;
var
  LSep: string;
begin
  // Optional parameter: use a default when the AI doesn't provide it
  if Separator.IsEmpty then
    LSep := ' '
  else
    LSep := Separator;
  Result := TMCPToolResult.Text(A + LSep + B);
end;

function TMyTools.IsPalindrome(const Value: string): TMCPToolResult;
var
  LLower: string;
begin
  LLower := LowerCase(Value);
  // FromValue(Boolean) returns "true" or "false" as text
  Result := TMCPToolResult.FromValue(LLower = System.StrUtils.ReverseString(LLower));
end;

// ---------------------------------------------------------------------------
// AUTO-REGISTRATION
// Just by adding this unit to the .dpr uses clause, all tools above become
// available to AI clients. No additional wiring is needed.
// ---------------------------------------------------------------------------
initialization
  TMCPServer.Instance.RegisterToolProvider(TMyTools);

end.
