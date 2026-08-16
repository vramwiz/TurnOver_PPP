unit Shake_PPP_RuntimeDeformer;

// Applies the two animatable grip offsets to one saved cloth range.

interface

uses
  AviUtl2FilterTypes,
  Shake_PPP_FilterSettings;

procedure InitializeRuntimeDeformer;
procedure FinalizeRuntimeDeformer;
procedure ApplyRuntimeDeformation(Video: PFILTER_PROC_VIDEO;
  const CurveDataText: string; const Settings: TTurnOverRuntimeSettings);

implementation

uses
  System.Generics.Collections,
  System.Math,
  System.SysUtils,
  System.Types,
  Winapi.Windows,
  Vcl.Graphics,
  AviUtl2FilterInfoUtils,
  Shake_PPP_CurveData,
  Shake_PPP_CurveModel,
  Shake_PPP_DebugLog,
  Shake_PPP_StaticDeformer;

type
  TTurnOverObjectState = class
  private
    FCurveDataText: string;
    FClothSettings: TTurnOverClothSettings;
    FFullFrameMode: Boolean;
    FGripVertexIndices: TShakeGripPointVertexIndices;
    FHeight: Integer;
    FMap: TShakeDeformationMap;
    FMapReady: Boolean;
{$IFDEF DEBUG}
    FLastDebugDumpFrame: Integer;
{$ENDIF}
    FOuterContour: TShakeCurve;
    FOutput: TBytes;
    FSource: TBytes;
    FWidth: Integer;
    function PrepareMap(Width, Height: Integer;
      const CurveDataText: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Apply(Video: PFILTER_PROC_VIDEO; const CurveDataText: string;
      const Settings: TTurnOverRuntimeSettings);
  end;

var
  RuntimeInitialized: Boolean;
  RuntimeLock: TRTLCriticalSection;
  RuntimeStates: TObjectDictionary<Int64, TTurnOverObjectState>;
{$IFDEF DEBUG}
  RuntimeDebugImageDumpsEnabled: Boolean;
{$ENDIF}

constructor TTurnOverObjectState.Create;
var
  GripIndex: Integer;
begin
  inherited;
  FOuterContour := TShakeCurve.Create;
  FClothSettings := DefaultTurnOverClothSettings;
  FMap := TShakeDeformationMap.Create;
{$IFDEF DEBUG}
  FLastDebugDumpFrame := Low(Integer);
{$ENDIF}
  for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
    FGripVertexIndices[GripIndex] := -1;
end;

{$IFDEF DEBUG}
procedure SaveDebugRgbaBitmap(const Pixels: TBytes; Width, Height: Integer;
  const FileName: string);
var
  Alpha: Integer;
  Bitmap: Vcl.Graphics.TBitmap;
  Destination: PByte;
  PixelOffset: NativeInt;
  X: Integer;
  Y: Integer;
begin
  if (Width <= 0) or (Height <= 0) or
    (Length(Pixels) <> NativeInt(Width) * Height * 4) then
    Exit;
  Bitmap := Vcl.Graphics.TBitmap.Create;
  try
    Bitmap.PixelFormat := pf32bit;
    Bitmap.SetSize(Width, Height);
    for Y := 0 to Height - 1 do
    begin
      Destination := Bitmap.ScanLine[Height - 1 - Y];
      for X := 0 to Width - 1 do
      begin
        PixelOffset := (NativeInt(Y) * Width + X) * 4;
        Alpha := Pixels[PixelOffset + 3];
        Destination[0] := Pixels[PixelOffset + 2] * Alpha div 255;
        Destination[1] := Pixels[PixelOffset + 1] * Alpha div 255;
        Destination[2] := Pixels[PixelOffset] * Alpha div 255;
        Destination[3] := 255;
        Inc(Destination, 4);
      end;
    end;
    Bitmap.SaveToFile(FileName);
  finally
    Bitmap.Free;
  end;
end;
{$ENDIF}

destructor TTurnOverObjectState.Destroy;
begin
  FMap.Free;
  FOuterContour.Free;
  inherited;
end;

function TTurnOverObjectState.PrepareMap(Width, Height: Integer;
  const CurveDataText: string): Boolean;
var
  ErrorText: string;
begin
  if (FWidth = Width) and (FHeight = Height) and
    (FCurveDataText = CurveDataText) then
    Exit(FMapReady);
  FWidth := Width;
  FHeight := Height;
  FCurveDataText := CurveDataText;
  FMapReady := False;
  FFullFrameMode := False;
  FMap.Clear;
  if not TryDecodeTurnOverCurveData(CurveDataText, FOuterContour,
    FGripVertexIndices, FClothSettings, ErrorText) then
  begin
    DebugLog('Runtime cloth data rejected: ' + ErrorText);
    Exit(False);
  end;
  FMapReady := FMap.Build(Width, Height, FOuterContour, nil,
    FClothSettings.FixedEdge, ErrorText);
  FFullFrameMode := FMapReady and IsFullFrameClothRange(FOuterContour);
  if not FMapReady and (ErrorText <> 'OUTER_NOT_CLOSED') then
    DebugLog('Runtime cloth range rejected: ' + ErrorText);
  Result := FMapReady;
end;

procedure TTurnOverObjectState.Apply(Video: PFILTER_PROC_VIDEO;
  const CurveDataText: string; const Settings: TTurnOverRuntimeSettings);
var
  AnimationFrame: Double;
  Billow: Double;
  BillowDisplacementX: Double;
  BillowDisplacementY: Double;
  GlobalBillowEnabled: Boolean;
  ByteCount: NativeInt;
  DirectionCosine: Double;
  DirectionRadians: Double;
  DirectionSine: Double;
  Enabled: TShakeGripEnabled;
  ErrorText: string;
  Frame: Integer;
  GripIndex: Integer;
  HasEnabledGrip: Boolean;
  HasMotion: Boolean;
  Height: Integer;
  OriginalPositions: TShakeGripPositions;
  Phase: Double;
  TargetPositions: TShakeGripPositions;
  Turbulence: Double;
  VertexIndex: Integer;
  Wave: Double;
  WindX: Double;
  WindY: Double;
  TightPartialCoverage: Boolean;
  Width: Integer;
begin
  if (Video = nil) or (Video^.Object_ = nil) or
    not Assigned(Video^.GetImageData) or
    not Assigned(Video^.SetImageData) then
    Exit;
  HasMotion := not (SameValue(Settings.GripOffsets[0].X, 0, 0.0001) and
    SameValue(Settings.GripOffsets[0].Y, 0, 0.0001) and
    SameValue(Settings.GripOffsets[1].X, 0, 0.0001) and
    SameValue(Settings.GripOffsets[1].Y, 0, 0.0001) and
    SameValue(Settings.WindStrength, 0, 0.0001) and
    SameValue(Settings.GravityStrength, 0, 0.0001) and
    SameValue(Settings.RippleStrength, 0, 0.0001));
  if not HasMotion and SameValue(Settings.ShrinkRate, 1, 0.0001) then
    Exit;
  Width := Video^.Object_^.Width;
  Height := Video^.Object_^.Height;
  if (Width <= 0) or (Height <= 0) or
    (NativeInt(Width) > High(NativeInt) div Height div 4) or
    not PrepareMap(Width, Height, CurveDataText) then
    Exit;
  if not HasMotion and
    (not FFullFrameMode or SameValue(Settings.ShrinkRate, 1, 0.0001)) then
    Exit;
  Frame := AviUtl2GetVideoFrame(Video);
  AnimationFrame := Frame * EnsureRange(Settings.AnimationSpeed, 0.0, 4.0);
  DirectionRadians := DegToRad(Settings.WindDirectionDegrees);
  DirectionCosine := Cos(DirectionRadians);
  DirectionSine := Sin(DirectionRadians);
  Turbulence := EnsureRange(Settings.WindTurbulence, 0.0, 1.0);
  GlobalBillowEnabled :=
    (FClothSettings.BillowStyle in [tbsBend, tbsSway, tbsFlutter]) and
    ((Settings.WindStrength > 0) or
    ((FClothSettings.BillowStyle = tbsFlutter) and
    (Settings.RippleStrength > 0)));
  BillowDisplacementX := 0;
  BillowDisplacementY := 0;
  if GlobalBillowEnabled then
  begin
    Phase := 2 * Pi * AnimationFrame / Max(1.0, Settings.WindPeriod);
    Wave := Sin(Phase) + Sin(Phase * 2.17) * 0.25 * Turbulence;
    Billow := (1 - Cos(Phase)) * 0.25 +
      (1 - Cos(Phase * 1.73)) * 0.06 * Turbulence;
    if FClothSettings.BillowStyle = tbsFlutter then
    begin
      { A flag receives a mostly steady push in the configured direction.
        Its upward lift directly opposes screen-down gravity; the moving LUT
        in the static deformer supplies the irregular travelling component. }
      Billow := EnsureRange(0.82 + Wave * 0.10 + Billow * 0.08,
        0.55, 1.10);
      BillowDisplacementX := DirectionCosine * Settings.WindStrength * Billow;
      BillowDisplacementY := DirectionSine * Settings.WindStrength * Billow -
        Settings.WindStrength * (0.30 + 0.08 * Turbulence);
    end
    else
    begin
      BillowDisplacementX :=
        (Wave * DirectionCosine + Billow * DirectionSine) *
        Settings.WindStrength;
      BillowDisplacementY :=
        (Wave * DirectionSine - Billow * DirectionCosine) *
        Settings.WindStrength;
    end;
  end;
  HasEnabledGrip := False;
  for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
  begin
    VertexIndex := FGripVertexIndices[GripIndex];
    Enabled[GripIndex] := (VertexIndex >= 0) and
      (VertexIndex < FOuterContour.Count);
    if Enabled[GripIndex] then
    begin
      HasEnabledGrip := True;
      OriginalPositions[GripIndex] := FOuterContour[VertexIndex].Position;
      Phase := 2 * Pi * AnimationFrame / Max(1.0, Settings.WindPeriod) +
        GripIndex * Pi / 5;
      Wave := Sin(Phase) + Sin(Phase * 2.17 + GripIndex * 1.37) *
        0.25 * Turbulence;
      Billow := (1 - Cos(Phase)) * 0.25 +
        (1 - Cos(Phase * 1.73 + GripIndex * 0.91)) *
        0.06 * Turbulence;
      WindX := (Wave * DirectionCosine + Billow * DirectionSine) *
        Settings.WindStrength;
      WindY := (Wave * DirectionSine - Billow * DirectionCosine) *
        Settings.WindStrength;
      if GlobalBillowEnabled then
      begin
        WindX := 0;
        WindY := 0;
      end;
      TargetPositions[GripIndex].X := OriginalPositions[GripIndex].X +
        (Settings.GripOffsets[GripIndex].X + WindX) /
        Max(1, Width - 1);
      TargetPositions[GripIndex].Y := OriginalPositions[GripIndex].Y +
        (Settings.GripOffsets[GripIndex].Y + WindY) /
        Max(1, Height - 1);
    end
    else
    begin
      OriginalPositions[GripIndex] := PointF(0, 0);
      TargetPositions[GripIndex] := PointF(0, 0);
    end;
  end;
  if not HasEnabledGrip and not GlobalBillowEnabled and
    (Settings.GravityStrength <= 0) and
    (not FFullFrameMode or (Settings.ShrinkRate >= 1)) then
    Exit;
  TightPartialCoverage :=
    SameValue(Settings.GripOffsets[0].X, 0, 0.0001) and
    SameValue(Settings.GripOffsets[0].Y, 0, 0.0001) and
    SameValue(Settings.GripOffsets[1].X, 0, 0.0001) and
    SameValue(Settings.GripOffsets[1].Y, 0, 0.0001) and
    ((Settings.WindStrength > 0) or (Settings.GravityStrength > 0) or
    (Settings.RippleStrength > 0));
  ByteCount := NativeInt(Width) * Height * 4;
  SetLength(FSource, ByteCount);
  SetLength(FOutput, ByteCount);
  Video^.GetImageData(PPIXEL_RGBA(@FSource[0]));
{$IFDEF DEBUG}
  if RuntimeDebugImageDumpsEnabled and
    (Frame <> FLastDebugDumpFrame) then
    try
      SaveDebugRgbaBitmap(FSource, Width, Height,
        'C:\ProgramData\aviutl2\Plugin\TurnOver_PPP\debug_source.bmp');
      FMap.SaveDebugCoverageBitmap(
        'C:\ProgramData\aviutl2\Plugin\TurnOver_PPP\debug_coverage.bmp',
        TightPartialCoverage);
    except
      on E: Exception do
        DebugLog('Runtime source debug image save failed: ' + E.Message);
    end;
{$ENDIF}
  if not FMap.ApplyGripRgba(@FSource[0], @FOutput[0], OriginalPositions,
    TargetPositions, Enabled, FClothSettings.BillowStyle,
    BillowDisplacementX, BillowDisplacementY, Settings.WindStrength,
    Settings.GravityStrength, Settings.ShrinkRate, Settings.FoldStrength,
    Settings.LightingStrength, Settings.BacksideStrength,
    Settings.InfluenceRadius, Settings.CastShadowStrength,
    Settings.RippleStrength, Settings.RippleCount,
    2 * Pi * AnimationFrame / Max(1.0, Settings.WindPeriod),
    Settings.WindDirectionDegrees,
    FFullFrameMode, TightPartialCoverage, ErrorText) then
  begin
    DebugLog('Runtime turnover deformation failed: ' + ErrorText);
    Exit;
  end;
{$IFDEF DEBUG}
  if RuntimeDebugImageDumpsEnabled and
    (Frame <> FLastDebugDumpFrame) then
  begin
    try
      SaveDebugRgbaBitmap(FOutput, Width, Height,
        'C:\ProgramData\aviutl2\Plugin\TurnOver_PPP\debug_output.bmp');
      DebugLog(Format(
        'Runtime debug images saved: frame=%d source=debug_source.bmp coverage=debug_coverage.bmp output=debug_output.bmp.',
        [Frame]));
    except
      on E: Exception do
        DebugLog('Runtime output debug image save failed: ' + E.Message);
    end;
    FLastDebugDumpFrame := Frame;
  end;
{$ENDIF}
  Video^.SetImageData(PPIXEL_RGBA(@FOutput[0]), Width, Height);
end;

procedure InitializeRuntimeDeformer;
begin
  if RuntimeInitialized then
    Exit;
{$IFDEF DEBUG}
  RuntimeDebugImageDumpsEnabled := SameText(
    GetEnvironmentVariable('TURNOVER_PPP_DEBUG_DUMP'), '1');
  if RuntimeDebugImageDumpsEnabled then
    DebugLog('Runtime debug image dumps enabled by TURNOVER_PPP_DEBUG_DUMP=1.');
{$ENDIF}
  InitializeCriticalSection(RuntimeLock);
  RuntimeStates := TObjectDictionary<Int64, TTurnOverObjectState>.Create(
    [doOwnsValues]);
  RuntimeInitialized := True;
end;

procedure FinalizeRuntimeDeformer;
begin
  if not RuntimeInitialized then
    Exit;
  EnterCriticalSection(RuntimeLock);
  try
    FreeAndNil(RuntimeStates);
  finally
    LeaveCriticalSection(RuntimeLock);
  end;
  DeleteCriticalSection(RuntimeLock);
  RuntimeInitialized := False;
end;

procedure ApplyRuntimeDeformation(Video: PFILTER_PROC_VIDEO;
  const CurveDataText: string; const Settings: TTurnOverRuntimeSettings);
var
  Key: Int64;
  State: TTurnOverObjectState;
begin
  if not RuntimeInitialized or (Video = nil) or (Video^.Object_ = nil) then
    Exit;
  Key := Video^.Object_^.EffectID;
  if Key = 0 then
    Key := Video^.Object_^.ID;
  EnterCriticalSection(RuntimeLock);
  try
    if not RuntimeStates.TryGetValue(Key, State) then
    begin
      State := TTurnOverObjectState.Create;
      RuntimeStates.Add(Key, State);
    end;
    State.Apply(Video, CurveDataText, Settings);
  finally
    LeaveCriticalSection(RuntimeLock);
  end;
end;

end.
