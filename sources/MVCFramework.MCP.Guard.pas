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

unit MVCFramework.MCP.Guard;

interface

uses
  System.SysUtils, System.Generics.Collections,
  MVCFramework, MVCFramework.Commons, MVCFramework.MinimalAPI;

type
  EMCPGuardException = class(Exception);

  TMCPGuardOptions = record
  private
    FEndpointPath: string;
    FTokens: TArray<TPair<string, string>>;   // name, value
    FAllowedOrigins: TArray<string>;
    FAllowedHosts: TArray<string>;
    FAuthElsewhere: Boolean;
  public
    class function Create: TMCPGuardOptions; static;
    { The full routed path of the published object, engine path prefix included
      (PublishObject(..., '/mcp') under a prefix '/api' is '/api/mcp'). Empty
      and '/' are refused (EMCPGuardException): they would guard the whole
      application. A guard whose path does not match the routed one vets
      nothing: a JSON-RPC POST to the endpoint and a DELETE on the session
      controller are then refused with 403 instead of served unguarded. The
      publisher's GET <path>, <path>/describe and <path>/proxy routes do not go
      through the endpoint's hook and are not refused by this check. }
    function EndpointPath(const APath: string): TMCPGuardOptions;
    function BearerToken(const AName, AValue: string): TMCPGuardOptions;
    function AllowedOrigins(const AOrigins: array of string): TMCPGuardOptions;
    { Host names (without port) accepted when the endpoint has no token, on top
      of localhost, 127.0.0.1 and [::1]. }
    function AllowedHosts(const AHosts: array of string): TMCPGuardOptions;
    { The application authenticates /mcp itself (JWT middleware): no token
      here, no "unauthenticated" warning, no Host rule. The endpoint then
      refuses (401) a request that reaches it without a valid logged user, so
      without something that authenticates, every request is refused. }
    function AuthenticationHandledElsewhere: TMCPGuardOptions;
  end;

{ One filter for the MCP endpoint: verbs, bearer token, Host and Origin.
  Register it before PublishObject and before any classic middleware:
    AEngine.UseHTTPFilter(MCPGuard(TMCPGuardOptions.Create.BearerToken('cli', lToken))); }
function MCPGuard(const AOptions: TMCPGuardOptions): TMVCHTTPFilter;

implementation

uses
  System.NetEncoding,
  MVCFramework.Logger, MVCFramework.MCP.Types, MVCFramework.MCP.Server;

class function TMCPGuardOptions.Create: TMCPGuardOptions;
begin
  Result := Default(TMCPGuardOptions);
  Result.FEndpointPath := MCP_ENDPOINT;
end;

function NormalizePath(const APath: string): string; forward;

function TMCPGuardOptions.EndpointPath(const APath: string): TMCPGuardOptions;
begin
  if NormalizePath(APath) = '' then
    raise EMCPGuardException.Create('MCPGuard: EndpointPath must name the endpoint, ' +
      'not the whole application (a path that normalises to empty is refused)');
  Result := Self;
  Result.FEndpointPath := APath;
end;

function TMCPGuardOptions.BearerToken(const AName, AValue: string): TMCPGuardOptions;
begin
  if AValue.Trim.IsEmpty then
    raise EMCPGuardException.CreateFmt('MCPGuard: the bearer token "%s" is empty', [AName]);
  if AValue <> AValue.Trim then
    raise EMCPGuardException.CreateFmt('MCPGuard: the bearer token "%s" has leading or ' +
      'trailing whitespace; a client token is trimmed, so it could never match', [AName]);
  Result := Self;
  Result.FTokens := Result.FTokens + [TPair<string, string>.Create(AName, AValue)];
end;

function TMCPGuardOptions.AllowedOrigins(const AOrigins: array of string): TMCPGuardOptions;
var
  LOrigin: string;
begin
  Result := Self;
  for LOrigin in AOrigins do
    if not LOrigin.Trim.IsEmpty then
      Result.FAllowedOrigins := Result.FAllowedOrigins + [LOrigin.Trim];
end;

function TMCPGuardOptions.AllowedHosts(const AHosts: array of string): TMCPGuardOptions;
var
  LHost: string;
begin
  Result := Self;
  for LHost in AHosts do
    if not LHost.Trim.IsEmpty then
      Result.FAllowedHosts := Result.FAllowedHosts + [LHost.Trim];
end;

function TMCPGuardOptions.AuthenticationHandledElsewhere: TMCPGuardOptions;
begin
  Result := Self;
  Result.FAuthElsewhere := True;
end;

{ Same length is not secret; the content is: no early exit on the first
  different character. }
function SameSecret(const A, B: string): Boolean;
var
  I: Integer;
  LDiff: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  LDiff := 0;
  for I := 1 to Length(A) do
    LDiff := LDiff or (Ord(A[I]) xor Ord(B[I]));
  Result := LDiff = 0;
end;

function HostWithoutPort(const AHost: string): string;
var
  LPos: Integer;
begin
  Result := AHost.Trim;
  if Result.StartsWith('[') then           // [::1]:8080
  begin
    LPos := Result.IndexOf(']');
    if LPos > 0 then
      Exit(Result.Substring(0, LPos + 1));
  end;
  LPos := Result.LastIndexOf(':');
  if LPos > 0 then
    Result := Result.Substring(0, LPos);
end;

{ The same shape the router gives a path before matching it: query dropped,
  Trim, leading '/', lower case, no trailing '/'. }
function NormalizePath(const APath: string): string;
var
  LPos: Integer;
begin
  Result := APath;
  LPos := Result.IndexOf('?');
  if LPos >= 0 then
    Result := Result.Substring(0, LPos);
  Result := Result.Trim;
  if not Result.StartsWith('/') then
    Result := '/' + Result;
  Result := Result.ToLower.TrimRight(['/']);
end;

{ The router never decodes before matching, so this candidate is defence in
  depth only: a malformed sequence must not make the guard raise on a path
  that has nothing to do with the endpoint. }
function SafeUrlDecode(const APath: string): string;
begin
  try
    Result := TNetEncoding.URL.Decode(APath);
  except
    Result := '';
  end;
end;

function InList(const AValue: string; const AList: TArray<string>): Boolean;
var
  LItem: string;
begin
  for LItem in AList do
    if SameText(AValue, LItem) then
      Exit(True);
  Result := False;
end;

function MCPGuard(const AOptions: TMCPGuardOptions): TMVCHTTPFilter;
const
  LOOPBACK_HOSTS: array [0 .. 2] of string = ('localhost', '127.0.0.1', '[::1]');
var
  LOptions: TMCPGuardOptions;
  LPath: string;
begin
  LOptions := AOptions;
  LPath := NormalizePath(LOptions.FEndpointPath);
  TMCPServer.Instance.GuardInstalled := True;
  if (Length(LOptions.FTokens) = 0) and not LOptions.FAuthElsewhere then
    LogW('MCP: ' + LOptions.FEndpointPath + ' is served over HTTP without authentication');

  Result :=
    procedure(const AContext: TWebContext; const ANext: TMVCHTTPFilterNext)
    var
      LCandidates: array [0 .. 2] of string;
      LCandidate, LAuth, LOrigin, LHost, LPresented: string;
      LGuarded, LExact: Boolean;
      LToken: TPair<string, string>;
      LLoopback: string;
      LHostOk, LTokenOk: Boolean;
    begin
      // The engine routes on RawPathInfo (PathInfo when that is shorter): test
      // both, and the decoded raw form, so guard and router cannot disagree.
      LCandidates[0] := NormalizePath(AContext.Request.PathInfo);
      LCandidates[1] := NormalizePath(AContext.Request.RawPathInfo);
      LCandidates[2] := NormalizePath(SafeUrlDecode(AContext.Request.RawPathInfo));
      LGuarded := False;
      LExact := True;
      for LCandidate in LCandidates do
        if (LCandidate = LPath) or LCandidate.StartsWith(LPath + '/') then
        begin
          LGuarded := True;
          if LCandidate <> LPath then
            LExact := False;
        end;
      if not LGuarded then
      begin
        ANext();
        Exit;
      end;

      if Length(LOptions.FTokens) > 0 then
      begin
        LAuth := AContext.Request.Headers['Authorization'];
        LPresented := '';
        if LAuth.StartsWith('Bearer ', True) then
          LPresented := LAuth.Substring(7).Trim;
        LTokenOk := False;
        for LToken in LOptions.FTokens do
          if (LPresented <> '') and SameSecret(LPresented, LToken.Value) then
          begin
            AContext.LoggedUser.UserName := LToken.Key;
            AContext.LoggedUser.LoggedSince := Now;
            LTokenOk := True;
            Break;
          end;
        if not LTokenOk then
        begin
          AContext.Response.SetCustomHeader('WWW-Authenticate', 'Bearer');
          AContext.Response.StatusCode := HTTP_STATUS.Unauthorized;
          Exit;
        end;
      end
      else if not LOptions.FAuthElsewhere then
      begin
        // Unauthenticated endpoint: a page that rebinds its own domain to this
        // address sends same-origin requests, which carry no Origin.
        LHost := HostWithoutPort(AContext.Request.Headers['Host']);
        LHostOk := InList(LHost, LOptions.FAllowedHosts);
        for LLoopback in LOOPBACK_HOSTS do
          if SameText(LHost, LLoopback) then
            LHostOk := True;
        if not LHostOk then
        begin
          AContext.Response.StatusCode := HTTP_STATUS.Forbidden;
          Exit;
        end;
      end;

      LOrigin := AContext.Request.Headers['Origin'];
      if (LOrigin <> '') and not InList(LOrigin, LOptions.FAllowedOrigins) then
      begin
        AContext.Response.StatusCode := HTTP_STATUS.Forbidden;
        Exit;
      end;

      if not LExact or
         not (AContext.Request.HTTPMethod in [httpPOST, httpDELETE]) then
      begin
        AContext.Response.SetCustomHeader('Allow', 'POST, DELETE');
        AContext.Response.StatusCode := HTTP_STATUS.MethodNotAllowed;
        Exit;
      end;

      if LOptions.FAuthElsewhere then
        AContext.Data[MCP_GUARD_MARK] := MCP_GUARD_VETTED_AUTH_ELSEWHERE
      else
        AContext.Data[MCP_GUARD_MARK] := MCP_GUARD_VETTED;
      ANext();
    end;
end;

end.
