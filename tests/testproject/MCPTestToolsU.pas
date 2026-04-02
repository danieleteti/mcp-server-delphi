// ***************************************************************************
//
// MCP Server for DMVCFramework
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

unit MCPTestToolsU;

interface

uses
  MVCFramework.MCP.ToolProvider,
  MVCFramework.MCP.Attributes;

type
  { Tools returning TextContent }
  TTextTools = class(TMCPToolProvider)
  public
    [MCPTool('reverse_string', 'Reverses a string')]
    function ReverseString(
      [MCPParam('The string to reverse')] const Value: string
    ): TMCPToolResult;

    [MCPTool('string_length', 'Returns the length of a string')]
    function StringLength(
      [MCPParam('The string to measure')] const Value: string
    ): TMCPToolResult;

    [MCPTool('echo', 'Echoes back the input message')]
    function Echo(
      [MCPParam('The message to echo')] const Message: string
    ): TMCPToolResult;

    [MCPTool('concat_strings', 'Concatenates two strings with a separator')]
    function ConcatStrings(
      [MCPParam('First string')] const A: string;
      [MCPParam('Second string')] const B: string;
      [MCPParam('Separator between the strings', False)] const Separator: string
    ): TMCPToolResult;
  end;

  { Tools testing all numeric and scalar types }
  TNumericTools = class(TMCPToolProvider)
  public
    [MCPTool('add_integers', 'Adds two integers')]
    function AddIntegers(
      [MCPParam('First integer')] const A: Integer;
      [MCPParam('Second integer')] const B: Integer
    ): TMCPToolResult;

    [MCPTool('add_floats', 'Adds two floating-point numbers')]
    function AddFloats(
      [MCPParam('First number')] const A: Double;
      [MCPParam('Second number')] const B: Double
    ): TMCPToolResult;

    [MCPTool('divide', 'Divides two numbers, returns error on division by zero')]
    function Divide(
      [MCPParam('Dividend')] const A: Double;
      [MCPParam('Divisor')] const B: Double
    ): TMCPToolResult;

    [MCPTool('is_even', 'Checks if an integer is even')]
    function IsEven(
      [MCPParam('The integer to check')] const Value: Integer
    ): TMCPToolResult;

    [MCPTool('negate_bool', 'Negates a boolean value')]
    function NegateBool(
      [MCPParam('The boolean to negate')] const Value: Boolean
    ): TMCPToolResult;

    [MCPTool('factorial', 'Computes factorial of an integer (max 20)')]
    function Factorial(
      [MCPParam('Non-negative integer (max 20)')] const N: Integer
    ): TMCPToolResult;
  end;

  { Tools testing JSON and object serialization }
  TSerializationTools = class(TMCPToolProvider)
  public
    [MCPTool('get_json_object', 'Returns a JSON object with sample data')]
    function GetJsonObject: TMCPToolResult;

    [MCPTool('get_person', 'Returns a serialized person object')]
    function GetPerson(
      [MCPParam('Person name')] const Name: string;
      [MCPParam('Person age')] const Age: Integer
    ): TMCPToolResult;

    [MCPTool('get_person_list', 'Returns a collection of sample persons')]
    function GetPersonList: TMCPToolResult;
  end;

  { Tools testing image, resource, and multi-content results }
  TContentTypeTools = class(TMCPToolProvider)
  public
    [MCPTool('get_image', 'Returns a small base64-encoded test image')]
    function GetImage: TMCPToolResult;

    [MCPTool('get_embedded_resource', 'Returns an embedded text resource')]
    function GetEmbeddedResource(
      [MCPParam('URI for the embedded resource')] const URI: string;
      [MCPParam('Text content of the resource')] const Content: string
    ): TMCPToolResult;

    [MCPTool('get_multi_content', 'Returns multiple content items (text + image + resource) via fluent API')]
    function GetMultiContent(
      [MCPParam('Text message to include')] const Message: string
    ): TMCPToolResult;

    [MCPTool('get_stream_image', 'Returns an image built from a TStream')]
    function GetStreamImage: TMCPToolResult;
  end;

  { Tools testing error results }
  TErrorTools = class(TMCPToolProvider)
  public
    [MCPTool('always_fail', 'Always returns an error result')]
    function AlwaysFail(
      [MCPParam('Error message to return')] const Message: string
    ): TMCPToolResult;
  end;

  { Helper class for serialization tests }
  TPerson = class
  private
    FName: string;
    FAge: Integer;
    FEmail: string;
  public
    property Name: string read FName write FName;
    property Age: Integer read FAge write FAge;
    property Email: string read FEmail write FEmail;
  end;

implementation

uses
  System.SysUtils, System.StrUtils, System.Classes,
  System.Generics.Collections,
  JsonDataObjects,
  MVCFramework.MCP.Server;

{ TTextTools }

function TTextTools.ReverseString(const Value: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(System.StrUtils.ReverseString(Value));
end;

function TTextTools.StringLength(const Value: string): TMCPToolResult;
begin
  Result := TMCPToolResult.FromValue(Length(Value));
end;

function TTextTools.Echo(const Message: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(Message);
end;

function TTextTools.ConcatStrings(const A, B, Separator: string): TMCPToolResult;
var
  LSep: string;
begin
  if Separator.IsEmpty then
    LSep := ' '
  else
    LSep := Separator;
  Result := TMCPToolResult.Text(A + LSep + B);
end;

{ TNumericTools }

function TNumericTools.AddIntegers(const A, B: Integer): TMCPToolResult;
begin
  Result := TMCPToolResult.FromValue(A + B);
end;

function TNumericTools.AddFloats(const A, B: Double): TMCPToolResult;
begin
  Result := TMCPToolResult.FromValue(A + B);
end;

function TNumericTools.Divide(const A, B: Double): TMCPToolResult;
begin
  if B = 0 then
    Result := TMCPToolResult.Error('Division by zero')
  else
    Result := TMCPToolResult.FromValue(A / B);
end;

function TNumericTools.IsEven(const Value: Integer): TMCPToolResult;
begin
  Result := TMCPToolResult.FromValue(Value mod 2 = 0);
end;

function TNumericTools.NegateBool(const Value: Boolean): TMCPToolResult;
begin
  Result := TMCPToolResult.FromValue(not Value);
end;

function TNumericTools.Factorial(const N: Integer): TMCPToolResult;
var
  LResult: Int64;
  I: Integer;
begin
  if (N < 0) or (N > 20) then
    Exit(TMCPToolResult.Error('N must be between 0 and 20'));
  LResult := 1;
  for I := 2 to N do
    LResult := LResult * I;
  Result := TMCPToolResult.FromValue(LResult);
end;

{ TSerializationTools }

function TSerializationTools.GetJsonObject: TMCPToolResult;
var
  LJSON: TJDOJsonObject;
begin
  LJSON := TJDOJsonObject.Create;
  try
    LJSON.S['server'] := 'DMVCFramework MCP';
    LJSON.S['protocol'] := '2025-03-26';
    LJSON.I['toolCount'] := TMCPServer.Instance.Tools.Count;
    LJSON.I['resourceCount'] := TMCPServer.Instance.Resources.Count;
    LJSON.I['promptCount'] := TMCPServer.Instance.Prompts.Count;
    Result := TMCPToolResult.JSON(LJSON);
  finally
    LJSON.Free;
  end;
end;

function TSerializationTools.GetPerson(const Name: string; const Age: Integer): TMCPToolResult;
var
  LPerson: TPerson;
begin
  LPerson := TPerson.Create;
  try
    LPerson.Name := Name;
    LPerson.Age := Age;
    LPerson.Email := LowerCase(Name) + '@example.com';
    Result := TMCPToolResult.FromObject(LPerson);
  finally
    LPerson.Free;
  end;
end;

function TSerializationTools.GetPersonList: TMCPToolResult;
var
  LList: TObjectList<TPerson>;
  LPerson: TPerson;
begin
  LList := TObjectList<TPerson>.Create(True);
  try
    LPerson := TPerson.Create;
    LPerson.Name := 'Alice';
    LPerson.Age := 30;
    LPerson.Email := 'alice@example.com';
    LList.Add(LPerson);

    LPerson := TPerson.Create;
    LPerson.Name := 'Bob';
    LPerson.Age := 25;
    LPerson.Email := 'bob@example.com';
    LList.Add(LPerson);

    Result := TMCPToolResult.FromCollection(LList);
  finally
    LList.Free;
  end;
end;

{ TContentTypeTools }

function TContentTypeTools.GetImage: TMCPToolResult;
begin
  // Minimal 1x1 red PNG pixel (base64)
  Result := TMCPToolResult.Image(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==',
    'image/png');
end;

function TContentTypeTools.GetEmbeddedResource(const URI, Content: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Resource(URI, Content, 'text/plain');
end;

function TContentTypeTools.GetMultiContent(const Message: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(Message)
    .AddImage(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==',
      'image/png')
    .AddResource('file:///test.txt', 'Resource content from multi-content tool', 'text/plain');
end;

function TContentTypeTools.GetStreamImage: TMCPToolResult;
var
  LStream: TStringStream;
begin
  // Simulate binary content via a stream
  LStream := TStringStream.Create('FAKE_PNG_BINARY_DATA');
  try
    LStream.Position := 0;
    Result := TMCPToolResult.FromStream(LStream, 'image/png');
  finally
    LStream.Free;
  end;
end;

{ TErrorTools }

function TErrorTools.AlwaysFail(const Message: string): TMCPToolResult;
begin
  Result := TMCPToolResult.Error(Message);
end;

initialization
  TMCPServer.Instance.RegisterToolProvider(TTextTools);
  TMCPServer.Instance.RegisterToolProvider(TNumericTools);
  TMCPServer.Instance.RegisterToolProvider(TSerializationTools);
  TMCPServer.Instance.RegisterToolProvider(TContentTypeTools);
  TMCPServer.Instance.RegisterToolProvider(TErrorTools);

end.
