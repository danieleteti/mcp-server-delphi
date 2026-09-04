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

unit MVCFramework.MCP.ToolProvider;

interface

uses
  JsonDataObjects, System.SysUtils, System.TypInfo, System.Classes, Data.DB;

{$SCOPEDENUMS ON}

type
  // Wire format produced by TMCPToolResult.FromDataSet.
  //
  //   Json  - one JSON object per row. Self-describing and trivially parsed,
  //           but every field name is repeated on every row.
  //   Table - a pipe-separated table with the header written once:
  //
  //             id | code | description | price
  //             1 | EL-001 | Laptop | 899.00
  //             2 | EL-002 | Monitor | 349.00
  //
  // Both carry the same information. Table is markedly cheaper in tokens on
  // wide or long result sets, and a tool result is re-sent to the model on
  // every subsequent turn of the run, so the saving is paid back once per
  // turn. Json remains the default: it is what existing tools already emit.
  //
  // Table formatting rules: NULL renders as an empty cell, floats and dates
  // use invariant formats (dot decimal separator, ISO-8601 dates) so the
  // model never has to guess a locale, embedded line breaks are folded to a
  // single space to keep one record per line, and binary blobs render as
  // <blob N bytes> rather than being dumped inline.
  TMCPDataSetFormat = (Json, Table);

{$SCOPEDENUMS OFF}

// Renders a dataset as the pipe table described above. Exposed because a tool
// that builds a multi-part result with AddText needs the table as a string,
// not as a TMCPToolResult of its own.
function MCPDataSetToTable(ADataSet: TDataSet): string;

type

  // Tool result record. Uses an interface-counted holder internally so that
  // record copies don't cause double-free or leaks. The TJDOJsonArray is freed
  // automatically when the last copy of the record goes out of scope, unless
  // ToJSON has been called (which transfers ownership to the returned object).
  //
  // MCP defines three content types (ref: https://modelcontextprotocol.io/specification/2025-03-26/server/tools):
  //   - TextContent:        {"type":"text", "text":"..."}
  //   - ImageContent:       {"type":"image", "data":"<base64>", "mimeType":"..."}
  //   - EmbeddedResource:   {"type":"resource", "resource":{"uri":"...", "mimeType":"...", "text":"..."}}
  //
  // Factory methods for MCP content types:
  //   Text(AText)                           -> single TextContent
  //   Error(AMessage)                       -> single TextContent with isError=true
  //   Image(ABase64Data, AMimeType)         -> single ImageContent
  //   Resource(AURI, AText, AMimeType)      -> single EmbeddedResource (text)
  //   ResourceBlob(AURI, ABase64, AMimeType)-> single EmbeddedResource (blob)
  //
  // Convenience methods for Delphi types (all produce TextContent with JSON):
  //   JSON(AJsonObject)                     -> TextContent with serialized TJDOJsonObject
  //   FromObject(AObject)                   -> TextContent with JSON-serialized TObject via DMVCFramework
  //   FromCollection(AList)                 -> TextContent with JSON array from TObjectList/IInterface list
  //   FromRecord<T>(ARecord)                -> TextContent with JSON-serialized record
  //   FromDataSet(ADataSet)                 -> TextContent with JSON array from TDataSet
  //   FromDataSet(ADataSet, AFormat)        -> same, as JSON rows or as a token-cheap pipe table
  //   FromValue(AInteger/ADouble/ABoolean)  -> TextContent with value as string
  //   FromStream(AStream, AMimeType)        -> ImageContent with base64-encoded stream
  //
  // Builder methods for multi-content results:
  //   AddText(AText)                        -> appends a TextContent item
  //   AddImage(ABase64Data, AMimeType)      -> appends an ImageContent item
  //   AddResource(AURI, AText, AMimeType)   -> appends an EmbeddedResource item

  TMCPToolResult = record
  private type
    IContentHolder = interface
      function GetContent: TJDOJsonArray;
      procedure ReleaseContent;
    end;
    TContentHolder = class(TInterfacedObject, IContentHolder)
    private
      FContent: TJDOJsonArray;
    public
      constructor Create(AContent: TJDOJsonArray);
      destructor Destroy; override;
      function GetContent: TJDOJsonArray;
      procedure ReleaseContent;
    end;
  private
    FHolder: IContentHolder;
    FIsError: Boolean;
    procedure EnsureHolder;
    function GetContentArray: TJDOJsonArray;
  public
    // --- MCP TextContent ---
    // Returns a single text content item
    class function Text(const AText: string): TMCPToolResult; static;
    // Returns a single text content item with isError=true
    class function Error(const AMessage: string): TMCPToolResult; static;

    // --- MCP ImageContent ---
    // Returns a single image content item from base64-encoded data
    class function Image(const ABase64Data, AMimeType: string): TMCPToolResult; static;

    // --- MCP AudioContent ---
    // Returns a single audio content item from base64-encoded data
    class function Audio(const ABase64Data, AMimeType: string): TMCPToolResult; static;

    // --- MCP EmbeddedResource ---
    // Returns a single embedded resource with text content
    class function Resource(const AURI, AText: string;
      const AMimeType: string = 'text/plain'): TMCPToolResult; static;
    // Returns a single embedded resource with base64 blob content
    class function ResourceBlob(const AURI, ABase64Data: string;
      const AMimeType: string = 'application/octet-stream'): TMCPToolResult; static;

    // --- Convenience: Delphi types -> TextContent with JSON ---
    // Serializes a TJDOJsonObject to text (caller retains ownership of AJSON)
    class function JSON(AJSON: TJDOJsonObject): TMCPToolResult; static;
    // Serializes a TObject to JSON text via DMVCFramework serializer (caller retains ownership)
    class function FromObject(AObject: TObject): TMCPToolResult; static;
    // Serializes a TObjectList or IInterface list to JSON array via DMVCFramework (caller retains ownership)
    class function FromCollection(AList: TObject): TMCPToolResult; static;
    // Serializes a record to JSON text via DMVCFramework serializer
    class function FromRecord(const ARecord: Pointer; ARecordTypeInfo: PTypeInfo): TMCPToolResult; static;
    // Serializes a TDataSet to JSON array text via DMVCFramework (caller retains ownership)
    class function FromDataSet(ADataSet: TDataSet): TMCPToolResult; overload; static;
    // Same, choosing the wire format: TMCPDataSetFormat.Table writes the field
    // names once as a header instead of repeating them on every row, which
    // costs the model far fewer tokens on wide result sets.
    // The dataset is walked from the first record and left on the record it
    // was on; caller retains ownership.
    class function FromDataSet(ADataSet: TDataSet;
      const AFormat: TMCPDataSetFormat): TMCPToolResult; overload; static;

    // --- Convenience: scalar values -> TextContent ---
    class function FromValue(const AValue: Integer): TMCPToolResult; overload; static;
    class function FromValue(const AValue: Int64): TMCPToolResult; overload; static;
    class function FromValue(const AValue: Double): TMCPToolResult; overload; static;
    class function FromValue(const AValue: Boolean): TMCPToolResult; overload; static;

    // --- Convenience: TStream -> ImageContent with base64 encoding ---
    // Encodes the stream content as base64 and returns an ImageContent item.
    // Reads from current position to end. Caller retains ownership of AStream.
    class function FromStream(AStream: TStream;
      const AMimeType: string = 'application/octet-stream'): TMCPToolResult; static;

    // --- Builder: append additional content items ---
    // All Add* methods return Self for fluent chaining:
    //   Result := TMCPToolResult.Text('Analysis complete')
    //               .AddImage(LChartBase64, 'image/png')
    //               .AddResource('file:///report.csv', LCsvData, 'text/csv');
    function AddText(const AText: string): TMCPToolResult;
    function AddImage(const ABase64Data, AMimeType: string): TMCPToolResult;
    function AddResource(const AURI, AText: string;
      const AMimeType: string = 'text/plain'): TMCPToolResult;

    // Converts to the JSON-RPC result object. Transfers content ownership.
    function ToJSON: TJDOJsonObject;

    property IsError: Boolean read FIsError;
  end;

  { Lightweight parameter descriptor for dynamically-registered tools.
    The scanner pre-computes JsonSchemaType to avoid needing PTypeInfo at
    registration time (which TMCPServer.RegisterDynamicProvider doesn't have). }
  TMCPDynamicParamDef = record
    Name: string;
    Description: string;
    Required: Boolean;
    TypeKind: TTypeKind;
    JsonSchemaType: string;
  end;

  { Tool descriptor for dynamically-registered tools (no RTTI method). }
  TMCPDynamicToolDef = record
    Name: string;
    Description: string;
    ControllerClassName: string; // for code-gen grouping
    Params: TArray<TMCPDynamicParamDef>;
  end;

  TMCPToolProvider = class
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { Override to return tool definitions for dynamic (non-RTTI) registration.
      Default returns empty — existing providers are unaffected. }
    function GetDynamicToolDefs: TArray<TMCPDynamicToolDef>; virtual;

    { Override to handle invocation for dynamic tools.
      Called by DoToolsCall when TMCPToolInfo.HandlerInstance is set.
      Default raises Exception('not implemented'). }
    function InvokeDynamic(const AToolName: string;
      AArguments: TJDOJsonObject): TMCPToolResult; virtual;
  end;

  TMCPToolProviderClass = class of TMCPToolProvider;

implementation

uses
  System.Rtti, System.NetEncoding,
  MVCFramework.Serializer.JsonDataObjects,
  MVCFramework.Serializer.Commons;

{ TMCPToolResult.TContentHolder }

constructor TMCPToolResult.TContentHolder.Create(AContent: TJDOJsonArray);
begin
  inherited Create;
  FContent := AContent;
end;

destructor TMCPToolResult.TContentHolder.Destroy;
begin
  FContent.Free;
  inherited;
end;

function TMCPToolResult.TContentHolder.GetContent: TJDOJsonArray;
begin
  Result := FContent;
end;

procedure TMCPToolResult.TContentHolder.ReleaseContent;
begin
  FContent := nil;
end;

{ TMCPToolResult - internal helpers }

procedure TMCPToolResult.EnsureHolder;
begin
  if FHolder = nil then
    FHolder := TContentHolder.Create(TJDOJsonArray.Create);
end;

function TMCPToolResult.GetContentArray: TJDOJsonArray;
begin
  EnsureHolder;
  Result := FHolder.GetContent;
end;

{ TMCPToolResult - MCP TextContent }

class function TMCPToolResult.Text(const AText: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  Result.FIsError := False;
  Result.FHolder := TContentHolder.Create(TJDOJsonArray.Create);
  LItem := Result.GetContentArray.AddObject;
  LItem.S['type'] := 'text';
  LItem.S['text'] := AText;
end;

class function TMCPToolResult.Error(const AMessage: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  Result.FIsError := True;
  Result.FHolder := TContentHolder.Create(TJDOJsonArray.Create);
  LItem := Result.GetContentArray.AddObject;
  LItem.S['type'] := 'text';
  LItem.S['text'] := AMessage;
end;

{ TMCPToolResult - MCP ImageContent }

class function TMCPToolResult.Image(const ABase64Data, AMimeType: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  Result.FIsError := False;
  Result.FHolder := TContentHolder.Create(TJDOJsonArray.Create);
  LItem := Result.GetContentArray.AddObject;
  LItem.S['type'] := 'image';
  LItem.S['data'] := ABase64Data;
  LItem.S['mimeType'] := AMimeType;
end;

{ TMCPToolResult - MCP AudioContent }

class function TMCPToolResult.Audio(const ABase64Data, AMimeType: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  Result.FIsError := False;
  Result.FHolder := TContentHolder.Create(TJDOJsonArray.Create);
  LItem := Result.GetContentArray.AddObject;
  LItem.S['type'] := 'audio';
  LItem.S['data'] := ABase64Data;
  LItem.S['mimeType'] := AMimeType;
end;

{ TMCPToolResult - MCP EmbeddedResource }

class function TMCPToolResult.Resource(const AURI, AText: string;
  const AMimeType: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  Result.FIsError := False;
  Result.FHolder := TContentHolder.Create(TJDOJsonArray.Create);
  LItem := Result.GetContentArray.AddObject;
  LItem.S['type'] := 'resource';
  LItem.O['resource'].S['uri'] := AURI;
  LItem.O['resource'].S['mimeType'] := AMimeType;
  LItem.O['resource'].S['text'] := AText;
end;

class function TMCPToolResult.ResourceBlob(const AURI, ABase64Data: string;
  const AMimeType: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  Result.FIsError := False;
  Result.FHolder := TContentHolder.Create(TJDOJsonArray.Create);
  LItem := Result.GetContentArray.AddObject;
  LItem.S['type'] := 'resource';
  LItem.O['resource'].S['uri'] := AURI;
  LItem.O['resource'].S['mimeType'] := AMimeType;
  LItem.O['resource'].S['blob'] := ABase64Data;
end;

{ TMCPToolResult - Convenience: JSON / Object / DataSet }

class function TMCPToolResult.JSON(AJSON: TJDOJsonObject): TMCPToolResult;
begin
  if AJSON <> nil then
    Result := TMCPToolResult.Text(AJSON.ToJSON(False))
  else
    Result := TMCPToolResult.Text('null');
end;

class function TMCPToolResult.FromObject(AObject: TObject): TMCPToolResult;
var
  LSerializer: TMVCJsonDataObjectsSerializer;
begin
  LSerializer := TMVCJsonDataObjectsSerializer.Create;
  try
    Result := TMCPToolResult.Text(LSerializer.SerializeObject(AObject));
  finally
    LSerializer.Free;
  end;
end;

class function TMCPToolResult.FromCollection(AList: TObject): TMCPToolResult;
var
  LSerializer: TMVCJsonDataObjectsSerializer;
begin
  LSerializer := TMVCJsonDataObjectsSerializer.Create;
  try
    Result := TMCPToolResult.Text(LSerializer.SerializeCollection(AList));
  finally
    LSerializer.Free;
  end;
end;

class function TMCPToolResult.FromRecord(const ARecord: Pointer; ARecordTypeInfo: PTypeInfo): TMCPToolResult;
var
  LSerializer: TMVCJsonDataObjectsSerializer;
begin
  LSerializer := TMVCJsonDataObjectsSerializer.Create;
  try
    Result := TMCPToolResult.Text(LSerializer.SerializeRecord(ARecord, ARecordTypeInfo));
  finally
    LSerializer.Free;
  end;
end;

class function TMCPToolResult.FromDataSet(ADataSet: TDataSet): TMCPToolResult;
var
  LSerializer: TMVCJsonDataObjectsSerializer;
begin
  LSerializer := TMVCJsonDataObjectsSerializer.Create;
  try
    Result := TMCPToolResult.Text(LSerializer.SerializeDataSet(ADataSet));
  finally
    LSerializer.Free;
  end;
end;

// Renders one field of the current record for the Table format. Invariant
// formats only: the model must never have to guess whether "1.234" is one
// thousand or one point something.
function FieldToTableCell(AField: TField): string;
begin
  if AField.IsNull then
    Exit('');

  case AField.DataType of
    ftBoolean:
      if AField.AsBoolean then
        Exit('true')
      else
        Exit('false');

    ftFloat, ftCurrency, ftBCD, ftFMTBcd, ftSingle, ftExtended:
      Exit(FloatToStr(AField.AsFloat, TFormatSettings.Invariant));

    ftDate:
      Exit(FormatDateTime('yyyy-mm-dd', AField.AsDateTime));
    ftTime:
      Exit(FormatDateTime('hh:nn:ss', AField.AsDateTime));
    ftDateTime, ftTimeStamp:
      Exit(FormatDateTime('yyyy-mm-dd hh:nn:ss', AField.AsDateTime));

    ftBlob, ftGraphic, ftVarBytes, ftBytes, ftOraBlob:
      Exit(Format('<blob %d bytes>', [Length(AField.AsBytes)]));
  end;

  // Everything else goes out as text, folded onto a single line so that one
  // record stays one row.
  Result := AField.AsString
    .Replace(#13#10, ' ', [rfReplaceAll])
    .Replace(#13, ' ', [rfReplaceAll])
    .Replace(#10, ' ', [rfReplaceAll]);
end;

// Pipe-separated table: header once, then one line per record. An empty
// dataset still emits the header, so the model learns the shape of the
// result even when there is no data.
function MCPDataSetToTable(ADataSet: TDataSet): string;
const
  SEP = ' | ';
var
  LBuilder: TStringBuilder;
  LBookmark: TBookmark;
  LUseBookmark: Boolean;
  I: Integer;
begin
  if (ADataSet = nil) or (ADataSet.FieldCount = 0) then
    Exit('');

  LBuilder := TStringBuilder.Create;
  try
    for I := 0 to ADataSet.FieldCount - 1 do
    begin
      if I > 0 then
        LBuilder.Append(SEP);
      LBuilder.Append(ADataSet.Fields[I].FieldName);
    end;
    LBuilder.AppendLine;

    // A unidirectional dataset cannot be bookmarked (GetBookmark raises), and
    // it cannot be walked twice either: there the caller gets the rows from
    // wherever the cursor already is, which is the only thing possible.
    LUseBookmark := not ADataSet.IsUniDirectional;
    ADataSet.DisableControls;
    if LUseBookmark then
      LBookmark := ADataSet.GetBookmark
    else
      LBookmark := nil;
    try
      if LUseBookmark then
        ADataSet.First;
      while not ADataSet.Eof do
      begin
        for I := 0 to ADataSet.FieldCount - 1 do
        begin
          if I > 0 then
            LBuilder.Append(SEP);
          LBuilder.Append(FieldToTableCell(ADataSet.Fields[I]));
        end;
        LBuilder.AppendLine;
        ADataSet.Next;
      end;
    finally
      if LUseBookmark then
      begin
        if ADataSet.BookmarkValid(LBookmark) then
          ADataSet.GotoBookmark(LBookmark);
        ADataSet.FreeBookmark(LBookmark);
      end;
      ADataSet.EnableControls;
    end;

    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

class function TMCPToolResult.FromDataSet(ADataSet: TDataSet;
  const AFormat: TMCPDataSetFormat): TMCPToolResult;
begin
  case AFormat of
    TMCPDataSetFormat.Table:
      Result := TMCPToolResult.Text(MCPDataSetToTable(ADataSet));
  else
    Result := TMCPToolResult.FromDataSet(ADataSet);
  end;
end;

{ TMCPToolResult - Convenience: scalar values }

class function TMCPToolResult.FromValue(const AValue: Integer): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(IntToStr(AValue));
end;

class function TMCPToolResult.FromValue(const AValue: Int64): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(IntToStr(AValue));
end;

class function TMCPToolResult.FromValue(const AValue: Double): TMCPToolResult;
begin
  Result := TMCPToolResult.Text(FloatToStr(AValue));
end;

class function TMCPToolResult.FromValue(const AValue: Boolean): TMCPToolResult;
begin
  if AValue then
    Result := TMCPToolResult.Text('true')
  else
    Result := TMCPToolResult.Text('false');
end;

{ TMCPToolResult - Convenience: Stream -> base64 ImageContent }

class function TMCPToolResult.FromStream(AStream: TStream;
  const AMimeType: string): TMCPToolResult;
var
  LBytes: TBytes;
  LBase64: string;
begin
  SetLength(LBytes, AStream.Size - AStream.Position);
  if Length(LBytes) > 0 then
    AStream.ReadBuffer(LBytes[0], Length(LBytes));
  LBase64 := TNetEncoding.Base64.EncodeBytesToString(LBytes);
  Result := TMCPToolResult.Image(LBase64, AMimeType);
end;

{ TMCPToolResult - Builder: multi-content }

function TMCPToolResult.AddText(const AText: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  LItem := GetContentArray.AddObject;
  LItem.S['type'] := 'text';
  LItem.S['text'] := AText;
  Result := Self;
end;

function TMCPToolResult.AddImage(const ABase64Data, AMimeType: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  LItem := GetContentArray.AddObject;
  LItem.S['type'] := 'image';
  LItem.S['data'] := ABase64Data;
  LItem.S['mimeType'] := AMimeType;
  Result := Self;
end;

function TMCPToolResult.AddResource(const AURI, AText: string;
  const AMimeType: string): TMCPToolResult;
var
  LItem: TJDOJsonObject;
begin
  LItem := GetContentArray.AddObject;
  LItem.S['type'] := 'resource';
  LItem.O['resource'].S['uri'] := AURI;
  LItem.O['resource'].S['mimeType'] := AMimeType;
  LItem.O['resource'].S['text'] := AText;
  Result := Self;
end;

{ TMCPToolResult - Serialization }

function TMCPToolResult.ToJSON: TJDOJsonObject;
var
  LContent: TJDOJsonArray;
begin
  Result := TJDOJsonObject.Create;
  if FHolder <> nil then
  begin
    LContent := FHolder.GetContent;
    FHolder.ReleaseContent;
    Result.A['content'] := LContent;
  end
  else
    Result.A['content'] := TJDOJsonArray.Create;
  if FIsError then
    Result.B['isError'] := True;
end;

{ TMCPToolProvider }

constructor TMCPToolProvider.Create;
begin
  inherited Create;
end;

destructor TMCPToolProvider.Destroy;
begin
  inherited;
end;

function TMCPToolProvider.GetDynamicToolDefs: TArray<TMCPDynamicToolDef>;
begin
  Result := nil;
end;

function TMCPToolProvider.InvokeDynamic(const AToolName: string;
  AArguments: TJDOJsonObject): TMCPToolResult;
begin
  raise Exception.CreateFmt('%s.InvokeDynamic not implemented', [ClassName]);
end;

end.
