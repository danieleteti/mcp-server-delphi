unit TestAuthHandlerU;

interface

uses
  System.Generics.Collections, MVCFramework;

type
  { Requires a JWT for everything except the login URL. With ALax set it
    requires nothing: the misconfiguration of a handler that does not know the
    MCP endpoint (a valid token is still read when one is presented). }
  TTestAuthHandler = class(TInterfacedObject, IMVCAuthenticationHandler)
  private
    FLax: Boolean;
  public
    constructor Create(ALax: Boolean = False);
  protected
    procedure OnRequest(const AContext: TWebContext; const AControllerQualifiedClassName: string;
      const AActionName: string; var AAuthenticationRequired: Boolean);
    procedure OnAuthentication(const AContext: TWebContext; const AUserName: string;
      const APassword: string; AUserRoles: TList<string>; var AIsValid: Boolean;
      const ASessionData: TSessionData);
    procedure OnAuthorization(const AContext: TWebContext; AUserRoles: TList<string>;
      const AControllerQualifiedClassName: string; const AActionName: string;
      var AIsAuthorized: Boolean);
  end;

implementation

constructor TTestAuthHandler.Create(ALax: Boolean);
begin
  inherited Create;
  FLax := ALax;
end;

procedure TTestAuthHandler.OnRequest(const AContext: TWebContext;
  const AControllerQualifiedClassName, AActionName: string; var AAuthenticationRequired: Boolean);
begin
  AAuthenticationRequired := not FLax;
end;

procedure TTestAuthHandler.OnAuthentication(const AContext: TWebContext; const AUserName,
  APassword: string; AUserRoles: TList<string>; var AIsValid: Boolean; const ASessionData: TSessionData);
begin
  AIsValid := (AUserName = 'alice') and (APassword = 'wonderland');
  if AIsValid then
    AUserRoles.Add('operator');
end;

procedure TTestAuthHandler.OnAuthorization(const AContext: TWebContext; AUserRoles: TList<string>;
  const AControllerQualifiedClassName, AActionName: string; var AIsAuthorized: Boolean);
begin
  AIsAuthorized := True;
end;

end.
