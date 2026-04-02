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

unit MVCFramework.MCP.Session;

interface

uses
  System.SysUtils, System.DateUtils, System.Generics.Collections,
  System.SyncObjs, MVCFramework.MCP.Types;

type
  IMCPSession = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    function GetSessionId: string;
    function GetClientInfo: TMCPClientInfo;
    procedure SetClientInfo(const AValue: TMCPClientInfo);
    function GetCreatedAt: TDateTime;
    function GetLastAccessedAt: TDateTime;
    procedure Touch;
    function GetInitialized: Boolean;
    procedure SetInitialized(AValue: Boolean);
    property SessionId: string read GetSessionId;
    property ClientInfo: TMCPClientInfo read GetClientInfo write SetClientInfo;
    property CreatedAt: TDateTime read GetCreatedAt;
    property LastAccessedAt: TDateTime read GetLastAccessedAt;
    property Initialized: Boolean read GetInitialized write SetInitialized;
  end;

  TMCPSession = class(TInterfacedObject, IMCPSession)
  private
    FSessionId: string;
    FClientInfo: TMCPClientInfo;
    FCreatedAt: TDateTime;
    FLastAccessedAt: TDateTime;
    FInitialized: Boolean;
  public
    constructor Create(const ASessionId: string);
    function GetSessionId: string;
    function GetClientInfo: TMCPClientInfo;
    procedure SetClientInfo(const AValue: TMCPClientInfo);
    function GetCreatedAt: TDateTime;
    function GetLastAccessedAt: TDateTime;
    procedure Touch;
    function GetInitialized: Boolean;
    procedure SetInitialized(AValue: Boolean);
  end;

  IMCPSessionManager = interface
    ['{B2C3D4E5-F6A7-8901-BCDE-F12345678901}']
    function CreateSession: IMCPSession;
    function GetSession(const ASessionId: string): IMCPSession;
    procedure DestroySession(const ASessionId: string);
    function SessionExists(const ASessionId: string): Boolean;
  end;

  TMCPInMemorySessionManager = class(TInterfacedObject, IMCPSessionManager)
  private
    FSessions: TDictionary<string, IMCPSession>;
    FLock: TCriticalSection;
    FSessionTimeoutMinutes: Integer;
  public
    constructor Create(ASessionTimeoutMinutes: Integer = 30);
    destructor Destroy; override;
    function CreateSession: IMCPSession;
    function GetSession(const ASessionId: string): IMCPSession;
    procedure DestroySession(const ASessionId: string);
    function SessionExists(const ASessionId: string): Boolean;
    procedure CleanupExpiredSessions;
  end;

implementation

{ TMCPSession }

constructor TMCPSession.Create(const ASessionId: string);
begin
  inherited Create;
  FSessionId := ASessionId;
  FCreatedAt := Now;
  FLastAccessedAt := FCreatedAt;
  FInitialized := False;
end;

function TMCPSession.GetSessionId: string;
begin
  Result := FSessionId;
end;

function TMCPSession.GetClientInfo: TMCPClientInfo;
begin
  Result := FClientInfo;
end;

procedure TMCPSession.SetClientInfo(const AValue: TMCPClientInfo);
begin
  FClientInfo := AValue;
end;

function TMCPSession.GetCreatedAt: TDateTime;
begin
  Result := FCreatedAt;
end;

function TMCPSession.GetLastAccessedAt: TDateTime;
begin
  Result := FLastAccessedAt;
end;

procedure TMCPSession.Touch;
begin
  FLastAccessedAt := Now;
end;

function TMCPSession.GetInitialized: Boolean;
begin
  Result := FInitialized;
end;

procedure TMCPSession.SetInitialized(AValue: Boolean);
begin
  FInitialized := AValue;
end;

{ TMCPInMemorySessionManager }

constructor TMCPInMemorySessionManager.Create(ASessionTimeoutMinutes: Integer);
begin
  inherited Create;
  FSessions := TDictionary<string, IMCPSession>.Create;
  FLock := TCriticalSection.Create;
  FSessionTimeoutMinutes := ASessionTimeoutMinutes;
end;

destructor TMCPInMemorySessionManager.Destroy;
begin
  FLock.Free;
  FSessions.Free;
  inherited;
end;

function TMCPInMemorySessionManager.CreateSession: IMCPSession;
var
  LSessionId: string;
begin
  LSessionId := TGUID.NewGuid.ToString;
  { Remove braces from GUID }
  LSessionId := Copy(LSessionId, 2, Length(LSessionId) - 2);
  Result := TMCPSession.Create(LSessionId);
  FLock.Enter;
  try
    FSessions.Add(LSessionId, Result);
  finally
    FLock.Leave;
  end;
end;

function TMCPInMemorySessionManager.GetSession(const ASessionId: string): IMCPSession;
begin
  Result := nil;
  FLock.Enter;
  try
    if FSessions.TryGetValue(ASessionId, Result) then
      Result.Touch;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPInMemorySessionManager.DestroySession(const ASessionId: string);
begin
  FLock.Enter;
  try
    FSessions.Remove(ASessionId);
  finally
    FLock.Leave;
  end;
end;

function TMCPInMemorySessionManager.SessionExists(const ASessionId: string): Boolean;
var
  LSession: IMCPSession;
begin
  FLock.Enter;
  try
    Result := FSessions.TryGetValue(ASessionId, LSession);
    if Result then
    begin
      { Check if session has expired }
      if MinutesBetween(Now, LSession.LastAccessedAt) > FSessionTimeoutMinutes then
      begin
        FSessions.Remove(ASessionId);
        Result := False;
      end
      else
        LSession.Touch;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPInMemorySessionManager.CleanupExpiredSessions;
var
  LExpired: TList<string>;
  LPair: TPair<string, IMCPSession>;
  LKey: string;
begin
  LExpired := TList<string>.Create;
  try
    FLock.Enter;
    try
      for LPair in FSessions do
      begin
        if MinutesBetween(Now, LPair.Value.LastAccessedAt) > FSessionTimeoutMinutes then
          LExpired.Add(LPair.Key);
      end;
      for LKey in LExpired do
        FSessions.Remove(LKey);
    finally
      FLock.Leave;
    end;
  finally
    LExpired.Free;
  end;
end;

end.
