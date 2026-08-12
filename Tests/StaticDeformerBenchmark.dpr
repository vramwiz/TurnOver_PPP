program StaticDeformerBenchmark;

{$APPTYPE CONSOLE}

uses
  System.Math,
  System.SysUtils,
  System.Types,
  Winapi.Windows,
  Vcl.Graphics,
  Shake_PPP_CurveModel in 'Source\Common\Model\Shake_PPP_CurveModel.pas',
  Shake_PPP_DebugLog in 'Source\Common\Diagnostics\Shake_PPP_DebugLog.pas',
  Shake_PPP_StaticDeformer in 'Source\Common\Render\Shake_PPP_StaticDeformer.pas';

procedure AddEllipse(Curve: TShakeCurve; CenterX, CenterY,
  RadiusX, RadiusY: Single);
const
  POINT_COUNT = 12;
var
  Angle: Double;
  I: Integer;
begin
  for I := 0 to POINT_COUNT - 1 do
  begin
    Angle := I * 2 * Pi / POINT_COUNT;
    Curve.AddVertex(PointF(CenterX + Cos(Angle) * RadiusX,
      CenterY + Sin(Angle) * RadiusY), svkSmooth);
  end;
  Curve.Closed := True;
end;

procedure Check(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

var
  AnchorX: Integer;
  AnchorY: Integer;
  CenterContour: TShakeCurve;
  Checksum: UInt64;
  DeformationMap: TShakeDeformationMap;
  Destination: TBitmap;
  Elapsed: UInt64;
  ErrorText: string;
  FrameIndex: Integer;
  FullFrameContour: TShakeCurve;
  FullFrameEnabled: TShakeGripEnabled;
  FullFrameOrigins: TShakeGripPositions;
  FullFrameTargets: TShakeGripPositions;
  GripEnabled: TShakeGripEnabled;
  GripOrigins: TShakeGripPositions;
  GripTargets: TShakeGripPositions;
  HasVacatedPixel: Boolean;
  MovedBeyondOriginalTop: Boolean;
  OuterContour: TShakeCurve;
  PixelOffset: NativeInt;
  Row: PByte;
  Source: TBitmap;
  SourceRgba: TBytes;
  StartedAt: UInt64;
  DestinationRgba: TBytes;
  UpperLeftIndex: Integer;
  UpperPathStep: Integer;
  UpperRightIndex: Integer;
  X: Integer;
  Y: Integer;
begin
  Source := TBitmap.Create;
  Destination := TBitmap.Create;
  DeformationMap := TShakeDeformationMap.Create;
  OuterContour := TShakeCurve.Create;
  CenterContour := TShakeCurve.Create;
  FullFrameContour := TShakeCurve.Create;
  try
    Source.PixelFormat := pf32bit;
    Source.SetSize(1024, 1024);
    for Y := 0 to Source.Height - 1 do
    begin
      Row := Source.ScanLine[Y];
      for X := 0 to Source.Width - 1 do
      begin
        Row[0] := Byte(X and $FF);
        Row[1] := Byte(Y and $FF);
        Row[2] := Byte((X + Y) and $FF);
        Row[3] := 255;
        Inc(Row, 4);
      end;
    end;
    AddEllipse(OuterContour, 0.5, 0.5, 0.42, 0.42);
    Check(TryGetUpperBoundary(OuterContour, UpperLeftIndex,
      UpperRightIndex, UpperPathStep),
      'Upper boundary was not detected.');
    Check((UpperLeftIndex = 8) and (UpperRightIndex = 11) and
      (UpperPathStep = 1),
      'Upper boundary path was detected incorrectly.');
    AddEllipse(CenterContour, 0.5, 0.5, 0.18, 0.18);
    FullFrameContour.AddVertex(PointF(0, 0), svkCorner);
    FullFrameContour.AddVertex(PointF(1, 0), svkCorner);
    FullFrameContour.AddVertex(PointF(1, 1), svkCorner);
    FullFrameContour.AddVertex(PointF(0, 1), svkCorner);
    FullFrameContour.Closed := True;
    if not IsFullFrameClothRange(FullFrameContour) then
      raise Exception.Create('Full-frame cloth range was not detected.');
    if IsFullFrameClothRange(OuterContour) then
      raise Exception.Create('Inset cloth range was detected as full-frame.');
    StartedAt := GetTickCount64;
    if not DeformationMap.Build(Source.Width, Source.Height,
      OuterContour, CenterContour, ErrorText) then
      raise Exception.Create(ErrorText);
    Elapsed := GetTickCount64 - StartedAt;
    Writeln(Format('1024x1024 map build: %d ms', [Elapsed]));
    StartedAt := GetTickCount64;
    for X := 0 to 29 do
      if not DeformationMap.Apply(Source, Destination,
        Sin(X / 5) * 61.4, Cos(X / 7) * 35.8, ErrorText) then
        raise Exception.Create(ErrorText);
    Elapsed := GetTickCount64 - StartedAt;
    Writeln(Format('30 frames: %d ms, average: %.1f ms',
      [Elapsed, Elapsed / 30.0]));
    GripEnabled[0] := True;
    GripEnabled[1] := True;
    GripOrigins[0] := PointF(0.2, 0.5);
    GripOrigins[1] := PointF(0.8, 0.5);
    GripTargets[0] := PointF(0.28, 0.35);
    GripTargets[1] := PointF(0.72, 0.3);
    if not DeformationMap.ApplyGripPreview(Source, Destination,
      GripOrigins, GripTargets, GripEnabled,
      IsFullFrameClothRange(OuterContour), ErrorText) then
      raise Exception.Create(ErrorText);
    SetLength(SourceRgba, NativeInt(Source.Width) * Source.Height * 4);
    SetLength(DestinationRgba, Length(SourceRgba));
    for Y := 0 to Source.Height - 1 do
      for X := 0 to Source.Width - 1 do
      begin
        PixelOffset := (NativeInt(Y) * Source.Width + X) * 4;
        SourceRgba[PixelOffset] := Byte(X and $FF);
        SourceRgba[PixelOffset + 1] := Byte(Y and $FF);
        SourceRgba[PixelOffset + 2] := Byte((X + Y) and $FF);
        SourceRgba[PixelOffset + 3] := 255;
      end;
    if not DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], GripOrigins, GripTargets, GripEnabled,
      1.0, 1.0, 0.35, 0.38, 0.0, 0.0, 2.0, 0.0, 0.0,
      IsFullFrameClothRange(OuterContour), ErrorText) then
      raise Exception.Create(ErrorText);
    Check(PCardinal(@DestinationRgba[0])^ = PCardinal(@SourceRgba[0])^,
      'Partial selection changed a fixed outside pixel.');
    AnchorX := Round(OuterContour[8].Position.X * (Source.Width - 1));
    AnchorY := Round(OuterContour[8].Position.Y * (Source.Height - 1));
    PixelOffset := (NativeInt(AnchorY) * Source.Width + AnchorX) * 4;
    Check(PCardinal(@DestinationRgba[PixelOffset])^ =
      PCardinal(@SourceRgba[PixelOffset])^,
      'Partial selection moved its upper-left anchor.');
    AnchorX := Round(OuterContour[9].Position.X * (Source.Width - 1));
    AnchorY := Round(OuterContour[9].Position.Y * (Source.Height - 1));
    PixelOffset := (NativeInt(AnchorY) * Source.Width + AnchorX) * 4;
    Check(PCardinal(@DestinationRgba[PixelOffset])^ =
      PCardinal(@SourceRgba[PixelOffset])^,
      'Partial selection moved its upper seam.');
    AnchorX := Round(OuterContour[11].Position.X * (Source.Width - 1));
    AnchorY := Round(OuterContour[11].Position.Y * (Source.Height - 1));
    PixelOffset := (NativeInt(AnchorY) * Source.Width + AnchorX) * 4;
    Check(PCardinal(@DestinationRgba[PixelOffset])^ =
      PCardinal(@SourceRgba[PixelOffset])^,
      'Partial selection moved its upper-right anchor.');
    HasVacatedPixel := False;
    MovedBeyondOriginalTop := False;
    for Y := 0 to Source.Height - 1 do
      for X := 0 to Source.Width - 1 do
      begin
        PixelOffset := (NativeInt(Y) * Source.Width + X) * 4;
        if DestinationRgba[PixelOffset + 3] < 255 then
          HasVacatedPixel := True;
        if (Y < 82) and
          (PCardinal(@DestinationRgba[PixelOffset])^ <>
           PCardinal(@SourceRgba[PixelOffset])^) then
          MovedBeyondOriginalTop := True;
      end;
    Check(HasVacatedPixel,
      'Partial selection did not clear its vacated source area.');
    PixelOffset := (NativeInt(850) * Source.Width + 512) * 4;
    Check(DestinationRgba[PixelOffset + 3] = 0,
      'Partial selection left distant cloth at its source position.');
    Check(MovedBeyondOriginalTop,
      'Partial selection was clipped to its original bounds.');
    FillChar(SourceRgba[0], Length(SourceRgba), 255);
    FullFrameEnabled[0] := True;
    FullFrameEnabled[1] := False;
    FullFrameOrigins[0] := PointF(0, 0);
    FullFrameTargets[0] := PointF(0.25, 0.25);
    FullFrameOrigins[1] := PointF(0, 0);
    FullFrameTargets[1] := PointF(0, 0);
    if not DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], FullFrameOrigins, FullFrameTargets,
      FullFrameEnabled, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.0, 2.0, 0.0, 0.0,
      True, ErrorText) then
      raise Exception.Create(ErrorText);
    if DestinationRgba[3] <> 0 then
      raise Exception.Create('Full-frame vacated area was not transparent.');
    StartedAt := GetTickCount64;
    for FrameIndex := 0 to 29 do
      if not DeformationMap.ApplyGripRgba(@SourceRgba[0],
        @DestinationRgba[0], GripOrigins, GripTargets,
        GripEnabled, 1.0, 1.0, 0.35, 0.38, 0.25,
        15.0, 2.0, 2 * Pi * FrameIndex / 60, 17.0,
        True, ErrorText) then
        raise Exception.Create(ErrorText);
    Elapsed := GetTickCount64 - StartedAt;
    Writeln(Format('30 full-frame grip+ripple frames: %d ms, average: %.1f ms',
      [Elapsed, Elapsed / 30.0]));
    Checksum := 1469598103934665603;
    for X := 0 to Length(DestinationRgba) - 1 do
      Checksum := (Checksum xor UInt64(DestinationRgba[X])) *
        UInt64(1099511628211);
    Writeln('Output checksum: ', IntToHex(Checksum, 16));
  finally
    FullFrameContour.Free;
    CenterContour.Free;
    OuterContour.Free;
    Destination.Free;
    DeformationMap.Free;
    Source.Free;
  end;
end.
