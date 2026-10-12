// ***************************************************************************
//
// MCP Server for Delphi and Delphi MVC Framework - Test Server
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0 (the "License");
//
// ***************************************************************************

unit EngineConfigU;

interface

uses
  MVCFramework;

procedure ConfigureEngine(AEngine: TMVCEngine);

implementation

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  TestFlagsU,
  TestAuthHandlerU,
  MVCFramework.JWT,
  MVCFramework.Middleware.JWT,
  System.TypInfo,
  MVCFramework.Commons,
  MVCFramework.MinimalAPI,
  MVCFramework.MCP.Guard,
  MVCFramework.MCP.Server,
  MVCFramework.MCP.Bridge,
  // Test provider units self-register in their initialization sections.
  // Just listing them here is enough to activate the providers.
  MCPTestToolsU,
  MCPTestResourcesU,
  MCPTestPromptsU,
  MCPConformanceProvidersU,
  MCPBridgeTestControllerU;

function BridgeOptionsFromFlags: TMCPBridgeOptions;
var
  LValue: string;
  LMethods: TMVCHTTPMethods;
begin
  Result := TMCPBridgeOptions.Create;
  LMethods := [];
  for LValue in FlagValues('--bridge-exclude-methods') do
    Include(LMethods, TMVCHTTPMethodType(GetEnumValue(TypeInfo(TMVCHTTPMethodType), 'http' + LValue.ToUpper)));
  if LMethods <> [] then
    Result := Result.ExcludeMethods(LMethods);
  for LValue in FlagValues('--bridge-exclude-path') do
    Result := Result.ExcludePath(LValue);
  for LValue in FlagValues('--bridge-header') do
    Result := Result.Header(LValue.Substring(0, LValue.IndexOf('=')),
      LValue.Substring(LValue.IndexOf('=') + 1));
  for LValue in FlagValues('--bridge-only') do
    if SameText(LValue, 'TMCPBridgeOtherController') then
      Result := Result.OnlyControllers([TMCPBridgeOtherController])
    else
      Result := Result.OnlyControllers([TMCPBridgeTestController]);
end;

function BridgeThread(AEngine: TMVCEngine; const ABaseURL: string; AGate: TEvent;
  var AError: string): TThread;
var
  LErrorRef: PString;
begin
  LErrorRef := @AError;
  Result := TThread.CreateAnonymousThread(
    procedure
    begin
      AGate.WaitFor(INFINITE);
      try
        TMCPServer.Instance.RegisterFromEngine(AEngine, ABaseURL, BridgeOptionsFromFlags);
      except
        on E: Exception do
          LErrorRef^ := E.ClassName + ': ' + E.Message;
      end;
    end);
  Result.FreeOnTerminate := False;
end;

// Test only: the bridge registered from N threads at once (the WebBroker host
// runs the configuration procedure on request threads). Waits for all of them;
// if one raised, the first exception is raised again so the server fails to start.
procedure RegisterBridgeConcurrently(AEngine: TMVCEngine; ACount: Integer);
var
  LThreads: array of TThread;
  LErrors: array of string;
  LGate: TEvent;
  LBaseURL: string;
  I: Integer;
begin
  LBaseURL := 'http://localhost:' + FlagValue('--port', '8080');
  SetLength(LThreads, ACount);
  SetLength(LErrors, ACount);
  LGate := TEvent.Create(nil, True, False, '');
  try
    for I := 0 to ACount - 1 do
      LThreads[I] := BridgeThread(AEngine, LBaseURL, LGate, LErrors[I]);
    for I := 0 to ACount - 1 do
      LThreads[I].Start;
    LGate.SetEvent;
    for I := 0 to ACount - 1 do
      LThreads[I].WaitFor;
  finally
    for I := 0 to ACount - 1 do
      LThreads[I].Free;
    LGate.Free;
  end;
  for I := 0 to ACount - 1 do
    if LErrors[I] <> '' then
      raise Exception.Create('concurrent bridge registration failed: ' + LErrors[I]);
end;

function GuardOptionsFromFlags: TMCPGuardOptions;
var
  LValue: string;
begin
  Result := TMCPGuardOptions.Create;
  if FlagPresent('--jwt') or FlagPresent('--auth-elsewhere') then
    Result := Result.AuthenticationHandledElsewhere;
  if FlagPresent('--guard-path') then
    Result := Result.EndpointPath(FlagValue('--guard-path', ''));
  // name=value, or just value (named test-client)
  for LValue in FlagValues('--auth-token') do
    if LValue.Contains('=') then
      Result := Result.BearerToken(LValue.Substring(0, LValue.IndexOf('=')),
        LValue.Substring(LValue.IndexOf('=') + 1))
    else
      Result := Result.BearerToken('test-client', LValue);
  Result := Result.AllowedOrigins(FlagValues('--allowed-origin'));
  Result := Result.AllowedHosts(FlagValues('--allowed-host'));
end;

// Test only: reports who the guard authenticated, after the rest of the pipeline.
function EchoUserFilter: TMVCHTTPFilter;
begin
  Result :=
    procedure(const AContext: TWebContext; const ANext: TMVCHTTPFilterNext)
    begin
      ANext();
      if AContext.LoggedUserExists and (AContext.LoggedUser.UserName <> '') then
        AContext.Response.SetCustomHeader('X-Test-User', AContext.LoggedUser.UserName);
    end;
end;

procedure ConfigureEngine(AEngine: TMVCEngine);
begin
  if not FlagPresent('--no-guard') then
    AEngine.UseHTTPFilter(MCPGuard(GuardOptionsFromFlags));
  // After the guard (which marks the request), before the endpoint.
  if FlagPresent('--jwt') and FlagPresent('--jwt-no-iat') then
    // A claims setup without IssuedAt, and no check of it.
    AEngine.AddMiddleware(TMVCJWTAuthenticationMiddleware.Create(
      TTestAuthHandler.Create(False),
      procedure(const JWT: TJWT)
      begin
        JWT.Claims.Issuer := 'mcp-tests';
        JWT.Claims.ExpirationTime := Now + 1;
        JWT.Claims.NotBefore := Now - 1;
      end,
      'a-secret-long-enough-not-to-be-refused-at-startup',
      '/login',
      [TJWTCheckableClaim.ExpirationTime, TJWTCheckableClaim.NotBefore],
      300))
  else if FlagPresent('--jwt') then
    AEngine.AddMiddleware(TMVCJWTAuthenticationMiddleware.Create(
      TTestAuthHandler.Create(FlagPresent('--jwt-lax')),
      procedure(const JWT: TJWT)
      begin
        JWT.Claims.Issuer := 'mcp-tests';
        JWT.Claims.ExpirationTime := Now + 1;
        JWT.Claims.NotBefore := Now - 1;
        JWT.Claims.IssuedAt := Now;
      end,
      'a-secret-long-enough-not-to-be-refused-at-startup',
      '/login',
      [TJWTCheckableClaim.ExpirationTime, TJWTCheckableClaim.NotBefore, TJWTCheckableClaim.IssuedAt],
      300));
  if FlagPresent('--echo-user') then
    AEngine.UseHTTPFilter(EchoUserFilter());
  // Controllers
  // MCP session termination controller (HTTP DELETE on /mcp) per spec 2025-03-26.
  AEngine.AddController(TMCPSessionController);
  AEngine.AddController(TMCPBridgeTestController);
  AEngine.AddController(TMCPBridgeOtherController);
  // Controllers - END

  // Published objects
  AEngine.PublishObject(
    function: TObject
    begin
      Result := TMCPServer.Instance.CreatePublishedEndpoint;
    end, '/mcp');
  // Published objects - END

  if FlagPresent('--bridge-concurrent') then
    RegisterBridgeConcurrently(AEngine, StrToIntDef(FlagValue('--bridge-concurrent'), 8))
  else
    TMCPServer.Instance.RegisterFromEngine(AEngine,
      'http://localhost:' + FlagValue('--port', '8080'), BridgeOptionsFromFlags);
  // A host that builds one engine per worker (WebBroker web modules) runs the
  // configuration procedure again: the second registration must be a no-op.
  if FlagPresent('--bridge-twice') then
    TMCPServer.Instance.RegisterFromEngine(AEngine,
      'http://localhost:' + FlagValue('--port', '8080'), BridgeOptionsFromFlags);
end;

end.
