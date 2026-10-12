unit TestFlagsU;

interface

function FlagValue(const AName: string; const ADefault: string = ''): string;
function FlagValues(const AName: string): TArray<string>;
function FlagPresent(const AName: string): Boolean;

implementation

uses
  System.SysUtils;

function FlagValues(const AName: string): TArray<string>;
var
  I: Integer;
  LParam: string;
begin
  Result := nil;
  for I := 1 to ParamCount do
  begin
    LParam := ParamStr(I);
    if SameText(LParam, AName) and (I < ParamCount) then
      Result := Result + [ParamStr(I + 1)]
    else if LParam.StartsWith(AName + '=', True) then
      Result := Result + [LParam.Substring(Length(AName) + 1)];
  end;
end;

function FlagValue(const AName: string; const ADefault: string): string;
var
  LValues: TArray<string>;
begin
  LValues := FlagValues(AName);
  if Length(LValues) > 0 then
    Result := LValues[0]
  else
    Result := ADefault;
end;

function FlagPresent(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), AName) or ParamStr(I).StartsWith(AName + '=', True) then
      Exit(True);
  Result := False;
end;

end.
