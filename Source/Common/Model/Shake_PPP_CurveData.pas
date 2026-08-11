unit Shake_PPP_CurveData;

// Stores TurnOver's single cloth range and reads legacy Shake curve formats.

interface

uses
  Shake_PPP_CurveModel;

const
  MAX_SHAKE_CURVE_VERTICES = 512;
  MAX_SHAKE_CURVE_DATA_LENGTH = 32767;

function TryDecodeCurveData(const Text: string; OuterContour,
  CenterContour: TShakeCurve; out ErrorText: string): Boolean;
function TryEncodeCurveData(OuterContour, CenterContour: TShakeCurve;
  out Text, ErrorText: string): Boolean;
function TryDecodeCurveSets(const Text: string;
  const CurveSets: TShakeCurveSets; out ErrorText: string): Boolean; overload;
function TryDecodeCurveSets(const Text: string;
  const CurveSets: TShakeCurveSets; var GripVertexIndices:
  TShakeGripVertexIndices; out ErrorText: string): Boolean; overload;
function TryEncodeCurveSets(const CurveSets: TShakeCurveSets;
  out Text, ErrorText: string): Boolean; overload;
function TryEncodeCurveSets(const CurveSets: TShakeCurveSets;
  const GripVertexIndices: TShakeGripVertexIndices;
  out Text, ErrorText: string): Boolean; overload;
function TryDecodeTurnOverCurveData(const Text: string; OuterContour:
  TShakeCurve; var GripVertexIndices: TShakeGripPointVertexIndices;
  out ErrorText: string): Boolean;
function TryEncodeTurnOverCurveData(OuterContour: TShakeCurve;
  const GripVertexIndices: TShakeGripPointVertexIndices;
  out Text, ErrorText: string): Boolean;

implementation

uses
  System.Math,
  System.SysUtils,
  System.Types;

const
  CURVE_DATA_PREFIX_V1 = 'SPP1';
  CURVE_DATA_PREFIX_V2 = 'SPP2';
  CURVE_DATA_PREFIX_V3 = 'SPP3';
  TURNOVER_DATA_PREFIX_V1 = 'TPP1';

function InvariantFormatSettings: TFormatSettings;
begin
  Result := TFormatSettings.Create('en-US');
  Result.DecimalSeparator := '.';
end;

function EncodeCoordinate(Value: Single;
  const FormatSettings: TFormatSettings): string;
begin
  Result := FormatFloat('0.########', Value, FormatSettings);
end;

function TryEncodeCurve(const Marker: string; Curve: TShakeCurve;
  const FormatSettings: TFormatSettings; out Text, ErrorText: string): Boolean;
var
  I: Integer;
  Vertex: TShakeCurveVertex;
begin
  Text := '';
  ErrorText := '';
  if Curve = nil then
  begin
    ErrorText := Marker + '曲線がありません。';
    Exit(False);
  end;
  if Curve.Count > MAX_SHAKE_CURVE_VERTICES then
  begin
    ErrorText := Marker + '曲線の頂点数が上限を超えています。';
    Exit(False);
  end;
  Text := Marker + ',' + IntToStr(Ord(Curve.Closed));
  for I := 0 to Curve.Count - 1 do
  begin
    Vertex := Curve[I];
    if IsNan(Vertex.Position.X) or IsInfinite(Vertex.Position.X) or
      IsNan(Vertex.Position.Y) or IsInfinite(Vertex.Position.Y) or
      (Vertex.Position.X < 0) or (Vertex.Position.X > 1) or
      (Vertex.Position.Y < 0) or (Vertex.Position.Y > 1) then
    begin
      ErrorText := Marker + '曲線に不正な座標があります。';
      Exit(False);
    end;
    Text := Text + ';' + EncodeCoordinate(Vertex.Position.X, FormatSettings) +
      ',' + EncodeCoordinate(Vertex.Position.Y, FormatSettings) + ',' +
      IntToStr(Ord(Vertex.Kind));
  end;
  Result := True;
end;

function TryEncodeCurveData(OuterContour, CenterContour: TShakeCurve;
  out Text, ErrorText: string): Boolean;
var
  CenterText: string;
  FormatSettings: TFormatSettings;
  OuterText: string;
begin
  Text := '';
  ErrorText := '';
  FormatSettings := InvariantFormatSettings;
  if not TryEncodeCurve('O', OuterContour, FormatSettings,
    OuterText, ErrorText) then
    Exit(False);
  if not TryEncodeCurve('C', CenterContour, FormatSettings,
    CenterText, ErrorText) then
    Exit(False);
  Text := CURVE_DATA_PREFIX_V1 + '|' + OuterText + '|' + CenterText;
  if Length(Text) > MAX_SHAKE_CURVE_DATA_LENGTH then
  begin
    ErrorText := '曲線データが1行テキストの上限を超えています。';
    Text := '';
    Exit(False);
  end;
  Result := True;
end;

function TryEncodeCurveSets(const CurveSets: TShakeCurveSets;
  out Text, ErrorText: string): Boolean;
var
  CenterText1: string;
  CenterText2: string;
  FormatSettings: TFormatSettings;
  OuterText1: string;
  OuterText2: string;
begin
  Text := '';
  ErrorText := '';
  FormatSettings := InvariantFormatSettings;
  if not TryEncodeCurve('1O', CurveSets[0].OuterContour, FormatSettings,
    OuterText1, ErrorText) then
    Exit(False);
  if not TryEncodeCurve('1C', CurveSets[0].CenterContour, FormatSettings,
    CenterText1, ErrorText) then
    Exit(False);
  if not TryEncodeCurve('2O', CurveSets[1].OuterContour, FormatSettings,
    OuterText2, ErrorText) then
    Exit(False);
  if not TryEncodeCurve('2C', CurveSets[1].CenterContour, FormatSettings,
    CenterText2, ErrorText) then
    Exit(False);
  Text := CURVE_DATA_PREFIX_V2 + '|' + OuterText1 + '|' + CenterText1 +
    '|' + OuterText2 + '|' + CenterText2;
  if Length(Text) > MAX_SHAKE_CURVE_DATA_LENGTH then
  begin
    ErrorText := '曲線データが1行テキストの上限を超えています。';
    Text := '';
    Exit(False);
  end;
  Result := True;
end;

function TryEncodeGripAssignments(const Marker: string; OuterContour:
  TShakeCurve; Grip1VertexIndex, Grip2VertexIndex: Integer;
  out Text, ErrorText: string): Boolean;
begin
  Text := '';
  ErrorText := '';
  if OuterContour = nil then
  begin
    ErrorText := Marker + 'の外周曲線がありません。';
    Exit(False);
  end;
  if (Grip1VertexIndex < -1) or (Grip1VertexIndex >= OuterContour.Count) or
    (Grip2VertexIndex < -1) or (Grip2VertexIndex >= OuterContour.Count) then
  begin
    ErrorText := Marker + 'のつまみ頂点が範囲外です。';
    Exit(False);
  end;
  if (Grip1VertexIndex >= 0) and
    (Grip1VertexIndex = Grip2VertexIndex) then
  begin
    ErrorText := Marker + 'のつまみ1とつまみ2が重複しています。';
    Exit(False);
  end;
  Text := Marker + ',' + IntToStr(Grip1VertexIndex) + ',' +
    IntToStr(Grip2VertexIndex);
  Result := True;
end;

function TryEncodeTurnOverCurveData(OuterContour: TShakeCurve;
  const GripVertexIndices: TShakeGripPointVertexIndices;
  out Text, ErrorText: string): Boolean;
var
  FormatSettings: TFormatSettings;
  GripText: string;
  OuterText: string;
begin
  Text := '';
  ErrorText := '';
  FormatSettings := InvariantFormatSettings;
  if not TryEncodeCurve('O', OuterContour, FormatSettings,
    OuterText, ErrorText) then
    Exit(False);
  if not TryEncodeGripAssignments('G', OuterContour,
    GripVertexIndices[0], GripVertexIndices[1], GripText, ErrorText) then
    Exit(False);
  Text := TURNOVER_DATA_PREFIX_V1 + '|' + OuterText + '|' + GripText;
  if Length(Text) > MAX_SHAKE_CURVE_DATA_LENGTH then
  begin
    ErrorText := '曲線データが1行テキストの上限を超えています。';
    Text := '';
    Exit(False);
  end;
  Result := True;
end;

function TryEncodeCurveSets(const CurveSets: TShakeCurveSets;
  const GripVertexIndices: TShakeGripVertexIndices;
  out Text, ErrorText: string): Boolean;
var
  CenterText1: string;
  CenterText2: string;
  FormatSettings: TFormatSettings;
  GripText1: string;
  GripText2: string;
  OuterText1: string;
  OuterText2: string;
begin
  Text := '';
  ErrorText := '';
  FormatSettings := InvariantFormatSettings;
  if not TryEncodeCurve('1O', CurveSets[0].OuterContour, FormatSettings,
    OuterText1, ErrorText) then
    Exit(False);
  if not TryEncodeCurve('1C', CurveSets[0].CenterContour, FormatSettings,
    CenterText1, ErrorText) then
    Exit(False);
  if not TryEncodeGripAssignments('1G', CurveSets[0].OuterContour,
    GripVertexIndices[0, 0], GripVertexIndices[0, 1],
    GripText1, ErrorText) then
    Exit(False);
  if not TryEncodeCurve('2O', CurveSets[1].OuterContour, FormatSettings,
    OuterText2, ErrorText) then
    Exit(False);
  if not TryEncodeCurve('2C', CurveSets[1].CenterContour, FormatSettings,
    CenterText2, ErrorText) then
    Exit(False);
  if not TryEncodeGripAssignments('2G', CurveSets[1].OuterContour,
    GripVertexIndices[1, 0], GripVertexIndices[1, 1],
    GripText2, ErrorText) then
    Exit(False);
  Text := CURVE_DATA_PREFIX_V3 + '|' + OuterText1 + '|' + CenterText1 +
    '|' + GripText1 + '|' + OuterText2 + '|' + CenterText2 + '|' + GripText2;
  if Length(Text) > MAX_SHAKE_CURVE_DATA_LENGTH then
  begin
    ErrorText := '曲線データが1行テキストの上限を超えています。';
    Text := '';
    Exit(False);
  end;
  Result := True;
end;

function TryDecodeCurve(const Text, ExpectedMarker: string;
  const FormatSettings: TFormatSettings; Curve: TShakeCurve;
  out ErrorText: string): Boolean;
var
  ClosedValue: Integer;
  Fields: TArray<string>;
  I: Integer;
  KindValue: Integer;
  Position: TPointF;
  Records: TArray<string>;
begin
  Result := False;
  ErrorText := '';
  Records := Text.Split([';']);
  if (Length(Records) < 1) or
    (Length(Records) - 1 > MAX_SHAKE_CURVE_VERTICES) then
  begin
    ErrorText := ExpectedMarker + '曲線の頂点数が不正です。';
    Exit;
  end;
  Fields := Records[0].Split([',']);
  if (Length(Fields) <> 2) or (Fields[0] <> ExpectedMarker) or
    not TryStrToInt(Fields[1], ClosedValue) or
    (ClosedValue < 0) or (ClosedValue > 1) then
  begin
    ErrorText := ExpectedMarker + '曲線のヘッダーが不正です。';
    Exit;
  end;
  Curve.Clear;
  for I := 1 to High(Records) do
  begin
    Fields := Records[I].Split([',']);
    if (Length(Fields) <> 3) or
      not TryStrToFloat(Fields[0], Position.X, FormatSettings) or
      not TryStrToFloat(Fields[1], Position.Y, FormatSettings) or
      not TryStrToInt(Fields[2], KindValue) or
      (KindValue < Ord(Low(TShakeVertexKind))) or
      (KindValue > Ord(High(TShakeVertexKind))) or
      IsNan(Position.X) or IsInfinite(Position.X) or
      IsNan(Position.Y) or IsInfinite(Position.Y) or
      (Position.X < 0) or (Position.X > 1) or
      (Position.Y < 0) or (Position.Y > 1) then
    begin
      ErrorText := Format('%s曲線の頂点%dが不正です。',
        [ExpectedMarker, I]);
      Exit;
    end;
    Curve.AddVertex(Position, TShakeVertexKind(KindValue));
  end;
  Curve.Closed := (ClosedValue = 1) and (Curve.Count >= 3);
  if (ClosedValue = 1) and (Curve.Count < 3) then
  begin
    ErrorText := ExpectedMarker + '閉曲線の頂点が不足しています。';
    Exit;
  end;
  Result := True;
end;

function TryDecodeGripAssignments(const Text, ExpectedMarker: string;
  OuterContour: TShakeCurve; out Grip1VertexIndex, Grip2VertexIndex: Integer;
  out ErrorText: string): Boolean;
var
  Fields: TArray<string>;
begin
  Result := False;
  ErrorText := '';
  Fields := Text.Split([',']);
  if (Length(Fields) <> 3) or (Fields[0] <> ExpectedMarker) or
    not TryStrToInt(Fields[1], Grip1VertexIndex) or
    not TryStrToInt(Fields[2], Grip2VertexIndex) then
  begin
    ErrorText := ExpectedMarker + 'つまみデータが不正です。';
    Exit;
  end;
  if (Grip1VertexIndex < -1) or (Grip1VertexIndex >= OuterContour.Count) or
    (Grip2VertexIndex < -1) or (Grip2VertexIndex >= OuterContour.Count) then
  begin
    ErrorText := ExpectedMarker + 'つまみ頂点が範囲外です。';
    Exit;
  end;
  if (Grip1VertexIndex >= 0) and
    (Grip1VertexIndex = Grip2VertexIndex) then
  begin
    ErrorText := ExpectedMarker + 'つまみ頂点が重複しています。';
    Exit;
  end;
  Result := True;
end;

function TryDecodeCurveData(const Text: string; OuterContour,
  CenterContour: TShakeCurve; out ErrorText: string): Boolean;
var
  FormatSettings: TFormatSettings;
  Parts: TArray<string>;
  TemporaryCenter: TShakeCurve;
  TemporaryOuter: TShakeCurve;
begin
  Result := False;
  ErrorText := '';
  if (OuterContour = nil) or (CenterContour = nil) then
  begin
    ErrorText := '曲線の読み込み先がありません。';
    Exit;
  end;
  if Text = '' then
  begin
    OuterContour.Clear;
    CenterContour.Clear;
    Exit(True);
  end;
  if Length(Text) > MAX_SHAKE_CURVE_DATA_LENGTH then
  begin
    ErrorText := '曲線データが長すぎます。';
    Exit;
  end;
  Parts := Text.Split(['|']);
  if (Length(Parts) <> 3) or (Parts[0] <> CURVE_DATA_PREFIX_V1) then
  begin
    ErrorText := '未対応の曲線データ形式です。';
    Exit;
  end;
  FormatSettings := InvariantFormatSettings;
  TemporaryOuter := TShakeCurve.Create;
  TemporaryCenter := TShakeCurve.Create;
  try
    if not TryDecodeCurve(Parts[1], 'O', FormatSettings,
      TemporaryOuter, ErrorText) then
      Exit;
    if not TryDecodeCurve(Parts[2], 'C', FormatSettings,
      TemporaryCenter, ErrorText) then
      Exit;
    OuterContour.Assign(TemporaryOuter);
    CenterContour.Assign(TemporaryCenter);
    Result := True;
  finally
    TemporaryCenter.Free;
    TemporaryOuter.Free;
  end;
end;

function TryDecodeCurveSets(const Text: string;
  const CurveSets: TShakeCurveSets; out ErrorText: string): Boolean;
var
  IgnoredGripVertexIndices: TShakeGripVertexIndices;
begin
  Result := TryDecodeCurveSets(Text, CurveSets, IgnoredGripVertexIndices,
    ErrorText);
end;

function TryDecodeCurveSets(const Text: string;
  const CurveSets: TShakeCurveSets; var GripVertexIndices:
  TShakeGripVertexIndices; out ErrorText: string): Boolean;
var
  FormatSettings: TFormatSettings;
  GripIndex: Integer;
  I: Integer;
  Parts: TArray<string>;
  TemporaryGripVertexIndices: TShakeGripVertexIndices;
  TemporarySets: TShakeCurveSets;
begin
  Result := False;
  ErrorText := '';
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
      TemporaryGripVertexIndices[I, GripIndex] := -1;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    if (CurveSets[I].OuterContour = nil) or
      (CurveSets[I].CenterContour = nil) then
    begin
      ErrorText := '曲線の読み込み先がありません。';
      Exit;
    end;
  if Text = '' then
  begin
    for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    begin
      CurveSets[I].OuterContour.Clear;
      CurveSets[I].CenterContour.Clear;
      for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
        GripVertexIndices[I, GripIndex] := -1;
    end;
    Exit(True);
  end;
  if Length(Text) > MAX_SHAKE_CURVE_DATA_LENGTH then
  begin
    ErrorText := '曲線データが長すぎます。';
    Exit;
  end;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    TemporarySets[I].OuterContour := TShakeCurve.Create;
    TemporarySets[I].CenterContour := TShakeCurve.Create;
  end;
  try
    Parts := Text.Split(['|']);
    FormatSettings := InvariantFormatSettings;
    if (Length(Parts) = 3) and (Parts[0] = TURNOVER_DATA_PREFIX_V1) then
    begin
      if not TryDecodeCurve(Parts[1], 'O', FormatSettings,
        TemporarySets[0].OuterContour, ErrorText) or
        not TryDecodeGripAssignments(Parts[2], 'G',
        TemporarySets[0].OuterContour,
        TemporaryGripVertexIndices[0, 0],
        TemporaryGripVertexIndices[0, 1], ErrorText) then
        Exit;
    end
    else if (Length(Parts) = 3) and (Parts[0] = CURVE_DATA_PREFIX_V1) then
    begin
      if not TryDecodeCurve(Parts[1], 'O', FormatSettings,
        TemporarySets[0].OuterContour, ErrorText) or
        not TryDecodeCurve(Parts[2], 'C', FormatSettings,
        TemporarySets[0].CenterContour, ErrorText) then
        Exit;
    end
    else if (Length(Parts) = 5) and (Parts[0] = CURVE_DATA_PREFIX_V2) then
    begin
      if not TryDecodeCurve(Parts[1], '1O', FormatSettings,
        TemporarySets[0].OuterContour, ErrorText) or
        not TryDecodeCurve(Parts[2], '1C', FormatSettings,
        TemporarySets[0].CenterContour, ErrorText) or
        not TryDecodeCurve(Parts[3], '2O', FormatSettings,
        TemporarySets[1].OuterContour, ErrorText) or
        not TryDecodeCurve(Parts[4], '2C', FormatSettings,
        TemporarySets[1].CenterContour, ErrorText) then
        Exit;
    end
    else if (Length(Parts) = 7) and (Parts[0] = CURVE_DATA_PREFIX_V3) then
    begin
      if not TryDecodeCurve(Parts[1], '1O', FormatSettings,
        TemporarySets[0].OuterContour, ErrorText) or
        not TryDecodeCurve(Parts[2], '1C', FormatSettings,
        TemporarySets[0].CenterContour, ErrorText) or
        not TryDecodeGripAssignments(Parts[3], '1G',
        TemporarySets[0].OuterContour,
        TemporaryGripVertexIndices[0, 0],
        TemporaryGripVertexIndices[0, 1], ErrorText) or
        not TryDecodeCurve(Parts[4], '2O', FormatSettings,
        TemporarySets[1].OuterContour, ErrorText) or
        not TryDecodeCurve(Parts[5], '2C', FormatSettings,
        TemporarySets[1].CenterContour, ErrorText) or
        not TryDecodeGripAssignments(Parts[6], '2G',
        TemporarySets[1].OuterContour,
        TemporaryGripVertexIndices[1, 0],
        TemporaryGripVertexIndices[1, 1], ErrorText) then
        Exit;
    end
    else
    begin
      ErrorText := '未対応の曲線データ形式です。';
      Exit;
    end;
    for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
    begin
      CurveSets[I].OuterContour.Assign(TemporarySets[I].OuterContour);
      CurveSets[I].CenterContour.Assign(TemporarySets[I].CenterContour);
      for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
        GripVertexIndices[I, GripIndex] :=
          TemporaryGripVertexIndices[I, GripIndex];
    end;
    Result := True;
  finally
    for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
    begin
      TemporarySets[I].CenterContour.Free;
      TemporarySets[I].OuterContour.Free;
    end;
  end;
end;

function TryDecodeTurnOverCurveData(const Text: string; OuterContour:
  TShakeCurve; var GripVertexIndices: TShakeGripPointVertexIndices;
  out ErrorText: string): Boolean;
var
  I: Integer;
  TemporaryGripVertexIndices: TShakeGripVertexIndices;
  TemporarySets: TShakeCurveSets;
begin
  Result := False;
  ErrorText := '';
  if OuterContour = nil then
  begin
    ErrorText := '布の範囲の読み込み先がありません。';
    Exit;
  end;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    TemporarySets[I].OuterContour := TShakeCurve.Create;
    TemporarySets[I].CenterContour := TShakeCurve.Create;
  end;
  try
    if not TryDecodeCurveSets(Text, TemporarySets,
      TemporaryGripVertexIndices, ErrorText) then
      Exit;
    OuterContour.Assign(TemporarySets[0].OuterContour);
    GripVertexIndices := TemporaryGripVertexIndices[0];
    Result := True;
  finally
    for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
    begin
      TemporarySets[I].CenterContour.Free;
      TemporarySets[I].OuterContour.Free;
    end;
  end;
end;

end.
