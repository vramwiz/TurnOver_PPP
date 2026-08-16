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

{$IFDEF DEBUG}
procedure CheckFullFrameBend;
const
  IMAGE_SIZE = 128;
var
  BendMiddleRed: Byte;
  BottomY: Integer;
  Contour: TShakeCurve;
  DeformationMap: TShakeDeformationMap;
  DestinationRgba: TBytes;
  EdgeX: Integer;
  Enabled: TShakeGripEnabled;
  ErrorText: string;
  LeftBlendHalf: Double;
  LeftBlendQuarter: Double;
  LeftBlendThreeQuarters: Double;
  MaximumAdjacentStripDelta: Integer;
  Offset: NativeInt;
  Origins: TShakeGripPositions;
  PreviousStripShift: Integer;
  PreviousEdgeX: Integer;
  PreviousBottomY: Integer;
  SourceRgba: TBytes;
  StripChanged: Boolean;
  StripShift: Integer;
  VisibleBottomColumns: Integer;
  Targets: TShakeGripPositions;
  X: Integer;
  Y: Integer;
begin
  Contour := TShakeCurve.Create;
  DeformationMap := TShakeDeformationMap.Create;
  try
    Contour.AddVertex(PointF(0, 0), svkCorner);
    Contour.AddVertex(PointF(1, 0), svkCorner);
    Contour.AddVertex(PointF(1, 1), svkCorner);
    Contour.AddVertex(PointF(0, 1), svkCorner);
    Contour.Closed := True;
    Check(DeformationMap.Build(IMAGE_SIZE, IMAGE_SIZE, Contour, nil,
      tfeTop, ErrorText), ErrorText);
    SetLength(SourceRgba, IMAGE_SIZE * IMAGE_SIZE * 4);
    SetLength(DestinationRgba, Length(SourceRgba));
    for Y := 0 to IMAGE_SIZE - 1 do
      for X := 0 to IMAGE_SIZE - 1 do
      begin
        Offset := (NativeInt(Y) * IMAGE_SIZE + X) * 4;
        SourceRgba[Offset] := X;
        SourceRgba[Offset + 1] := Y;
        SourceRgba[Offset + 2] := X xor Y;
        SourceRgba[Offset + 3] := 255;
      end;
    FillChar(Enabled, SizeOf(Enabled), 0);
    FillChar(Origins, SizeOf(Origins), 0);
    FillChar(Targets, SizeOf(Targets), 0);
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsBend,
      12.0, 0.0, 12.0, 0.0, 1.0, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.0, 2.0, 0.0, 0.0, True, False, ErrorText), ErrorText);
    Offset := NativeInt(64) * 4;
    Check(PCardinal(@DestinationRgba[Offset])^ =
      PCardinal(@SourceRgba[Offset])^,
      'Full-frame bend moved the fixed edge.');
    Offset := (NativeInt(IMAGE_SIZE - 1) * IMAGE_SIZE + 64) * 4;
    Check(DestinationRgba[Offset] = 52,
      Format('Full-frame bend did not move the free edge: %d',
      [DestinationRgba[Offset]]));
    Offset := (NativeInt(IMAGE_SIZE div 2) * IMAGE_SIZE + 64) * 4;
    BendMiddleRed := DestinationRgba[Offset];
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsSway,
      12.0, 0.0, 12.0, 0.0, 1.0, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.0, 2.0, 0.0, 0.0, True, False, ErrorText), ErrorText);
    Offset := NativeInt(64) * 4;
    Check(PCardinal(@DestinationRgba[Offset])^ =
      PCardinal(@SourceRgba[Offset])^,
      'Full-frame sway moved the fixed edge.');
    Offset := (NativeInt(IMAGE_SIZE - 1) * IMAGE_SIZE + 64) * 4;
    Check(DestinationRgba[Offset] = 52,
      Format('Full-frame sway did not move the free edge: %d',
      [DestinationRgba[Offset]]));
    Offset := (NativeInt(IMAGE_SIZE div 2) * IMAGE_SIZE + 64) * 4;
    Check(DestinationRgba[Offset] < BendMiddleRed,
      Format('Sway did not make the cloth body follow sooner: %d >= %d',
      [DestinationRgba[Offset], BendMiddleRed]));
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsFlutter,
      0.0, 0.0, 12.0, 0.0, 1.0, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.0, 2.0, Pi / 2, 0.0, True, False, ErrorText), ErrorText);
    Offset := NativeInt(64) * 4;
    Check(PCardinal(@DestinationRgba[Offset])^ =
      PCardinal(@SourceRgba[Offset])^,
      'Full-frame flutter moved the fixed edge.');
    Offset := (NativeInt(IMAGE_SIZE - 1) * IMAGE_SIZE + 64) * 4;
    Check(DestinationRgba[Offset + 1] < IMAGE_SIZE - 1,
      Format('Full-frame flutter did not wave at the free edge: %d',
      [DestinationRgba[Offset + 1]]));
    Check(DeformationMap.Build(IMAGE_SIZE, IMAGE_SIZE, Contour, nil,
      tfeLeft, ErrorText), ErrorText);
    LeftBlendQuarter := DeformationMap.DebugFixedTopBlendAt(
      IMAGE_SIZE div 4, IMAGE_SIZE - 1);
    LeftBlendHalf := DeformationMap.DebugFixedTopBlendAt(
      IMAGE_SIZE div 2, IMAGE_SIZE - 1);
    LeftBlendThreeQuarters := DeformationMap.DebugFixedTopBlendAt(
      IMAGE_SIZE * 3 div 4, IMAGE_SIZE - 1);
    Check((LeftBlendQuarter < LeftBlendHalf) and
      (LeftBlendHalf < LeftBlendThreeQuarters) and
      (LeftBlendThreeQuarters < 0.95),
      Format('Left-fixed bottom blend stopped before the right edge: %.3f, %.3f, %.3f',
      [LeftBlendQuarter, LeftBlendHalf, LeftBlendThreeQuarters]));
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsFlutter,
      0.0, 0.0, 0.0, 12.0, 1.0, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.0, 2.0, 0.0, 0.0, True, False, ErrorText), ErrorText);
    Offset := (NativeInt(64) * IMAGE_SIZE) * 4;
    Check(PCardinal(@DestinationRgba[Offset])^ =
      PCardinal(@SourceRgba[Offset])^,
      'Gravity moved the left fixed edge.');
    Offset := (NativeInt(64) * IMAGE_SIZE + IMAGE_SIZE - 1) * 4;
    Check(DestinationRgba[Offset + 1] = 52,
      Format('Gravity did not lower the right free edge: %d',
      [DestinationRgba[Offset + 1]]));
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsFlutter,
      0.0, -30.0, 0.0, 12.0, 1.0, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.0, 2.0, 0.0, 0.0, True, False, ErrorText), ErrorText);
    Offset := (NativeInt(64) * IMAGE_SIZE + IMAGE_SIZE - 1) * 4;
    Check(DestinationRgba[Offset + 1] = 82,
      Format('Flutter lift did not overcome gravity: %d',
      [DestinationRgba[Offset + 1]]));
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsFlutter,
      0.0, 0.0, 80.0, 0.0, 1.0, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.0, 2.0, 0.0, 0.0, True, False, ErrorText), ErrorText);
    Offset := (NativeInt(64) * IMAGE_SIZE) * 4;
    Check(PCardinal(@DestinationRgba[Offset])^ =
      PCardinal(@SourceRgba[Offset])^,
      'Vertical-strip flutter moved the left fixed edge.');
    StripChanged := False;
    MaximumAdjacentStripDelta := 0;
    PreviousStripShift := 0;
    for Y := 24 to IMAGE_SIZE - 25 do
    begin
      Offset := (NativeInt(Y) * IMAGE_SIZE + IMAGE_SIZE div 2) * 4;
      StripShift := Integer(DestinationRgba[Offset]) - IMAGE_SIZE div 2;
      if (Y > 24) and (StripShift <> PreviousStripShift) then
        StripChanged := True;
      if Y > 24 then
        MaximumAdjacentStripDelta := Max(MaximumAdjacentStripDelta,
          Abs(StripShift - PreviousStripShift));
      Check(DestinationRgba[Offset + 1] = Y,
        Format('Left-fixed flutter stretched row %d vertically: %d',
        [Y, DestinationRgba[Offset + 1]]));
      PreviousStripShift := StripShift;
    end;
    Check(StripChanged,
      'Left-fixed flutter did not vary adjacent one-pixel vertical strips.');
    Check(MaximumAdjacentStripDelta <= 3,
      Format('Left-fixed flutter tore adjacent strips apart: %d px',
      [MaximumAdjacentStripDelta]));
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsFlutter,
      0.0, 0.0, 400.0, 0.0, 1.0, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.0, 2.0, -Pi / 2, 0.0, True, False, ErrorText), ErrorText);
    MaximumAdjacentStripDelta := 0;
    PreviousEdgeX := -1;
    for Y := 24 to IMAGE_SIZE - 25 do
    begin
      EdgeX := -1;
      for X := IMAGE_SIZE - 1 downto 0 do
      begin
        Offset := (NativeInt(Y) * IMAGE_SIZE + X) * 4;
        if DestinationRgba[Offset + 3] <> 0 then
        begin
          EdgeX := X;
          Break;
        end;
      end;
      Check(EdgeX >= 0, Format('Strong flutter erased row %d.', [Y]));
      if PreviousEdgeX >= 0 then
        MaximumAdjacentStripDelta := Max(MaximumAdjacentStripDelta,
          Abs(EdgeX - PreviousEdgeX));
      PreviousEdgeX := EdgeX;
    end;
    Check(MaximumAdjacentStripDelta <= 5,
      Format('Strong flutter made a jagged free edge: %d px',
      [MaximumAdjacentStripDelta]));
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsFlutter,
      0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.35, 0.38, 0.0,
      100.0, 2.0, 0.0, 0.0, True, False, ErrorText), ErrorText);
    StripChanged := False;
    MaximumAdjacentStripDelta := 0;
    PreviousStripShift := 0;
    for Y := 24 to IMAGE_SIZE - 25 do
    begin
      Offset := (NativeInt(Y) * IMAGE_SIZE + IMAGE_SIZE div 2) * 4;
      StripShift := Integer(DestinationRgba[Offset]) - IMAGE_SIZE div 2;
      if (Y > 24) and (StripShift <> PreviousStripShift) then
        StripChanged := True;
      if Y > 24 then
        MaximumAdjacentStripDelta := Max(MaximumAdjacentStripDelta,
          Abs(StripShift - PreviousStripShift));
      Check(DestinationRgba[Offset + 1] = Y,
        Format('Wave-only flutter stretched row %d vertically: %d',
        [Y, DestinationRgba[Offset + 1]]));
      PreviousStripShift := StripShift;
    end;
    Check(StripChanged,
      'Wave-only flutter did not vary adjacent one-pixel vertical strips.');
    Check(MaximumAdjacentStripDelta <= 2,
      Format('Wave-only flutter tore adjacent strips apart: %d px',
      [MaximumAdjacentStripDelta]));
    Check(DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], Origins, Targets, Enabled, tbsFlutter,
      6.2, -1.0, 7.75, 13.75, 0.67, 1.0, 1.0, 0.35, 0.38, 0.0,
      0.625, 2.0, 0.0, 12.0, True, False, ErrorText), ErrorText);
    PreviousBottomY := -1;
    VisibleBottomColumns := 0;
    MaximumAdjacentStripDelta := 0;
    for X := IMAGE_SIZE div 2 to IMAGE_SIZE - 1 do
    begin
      BottomY := -1;
      for Y := IMAGE_SIZE - 1 downto 0 do
      begin
        Offset := (NativeInt(Y) * IMAGE_SIZE + X) * 4;
        if DestinationRgba[Offset + 3] <> 0 then
        begin
          BottomY := Y;
          Break;
        end;
      end;
      if BottomY < 0 then
        Continue;
      Inc(VisibleBottomColumns);
      if PreviousBottomY >= 0 then
        MaximumAdjacentStripDelta := Max(MaximumAdjacentStripDelta,
          Abs(BottomY - PreviousBottomY));
      PreviousBottomY := BottomY;
    end;
    Check(VisibleBottomColumns >= 32,
      'Shrink, gravity and flutter lost the lower-right cloth range.');
    Check(MaximumAdjacentStripDelta <= 3,
      Format('Lower-right cloth boundary was clipped: %d px',
      [MaximumAdjacentStripDelta]));
  finally
    DeformationMap.Free;
    Contour.Free;
  end;
end;

procedure CheckFixedEdgeBlendMaps;
const
  IMAGE_SIZE = 128;
var
  Contour: TShakeCurve;
  DeformationMap: TShakeDeformationMap;
  Edge: TTurnOverFixedEdge;
  ErrorText: string;
  FixedX: Integer;
  FixedY: Integer;
  MovableX: Integer;
  MovableY: Integer;
  TangentBoundaryX: Integer;
  TangentBoundaryY: Integer;
begin
  Contour := TShakeCurve.Create;
  DeformationMap := TShakeDeformationMap.Create;
  try
    Contour.AddVertex(PointF(0.1, 0.1), svkCorner);
    Contour.AddVertex(PointF(0.9, 0.1), svkCorner);
    Contour.AddVertex(PointF(0.9, 0.9), svkCorner);
    Contour.AddVertex(PointF(0.1, 0.9), svkCorner);
    Contour.Closed := True;
    for Edge := Low(TTurnOverFixedEdge) to High(TTurnOverFixedEdge) do
    begin
      Check(DeformationMap.Build(IMAGE_SIZE, IMAGE_SIZE, Contour, nil,
        Edge, ErrorText), ErrorText);
      case Edge of
        tfeTop:
          begin
            FixedX := 64; FixedY := 13;
            MovableX := 64; MovableY := 114;
            TangentBoundaryX := 13; TangentBoundaryY := 64;
          end;
        tfeBottom:
          begin
            FixedX := 64; FixedY := 114;
            MovableX := 64; MovableY := 13;
            TangentBoundaryX := 13; TangentBoundaryY := 64;
          end;
        tfeLeft:
          begin
            FixedX := 13; FixedY := 64;
            MovableX := 114; MovableY := 64;
            TangentBoundaryX := 64; TangentBoundaryY := 13;
          end;
      else
        begin
          FixedX := 114; FixedY := 64;
          MovableX := 13; MovableY := 64;
          TangentBoundaryX := 64; TangentBoundaryY := 13;
        end;
      end;
      Check(DeformationMap.DebugFixedTopBlendAt(FixedX, FixedY) < 0.01,
        Format('Fixed edge %d was not anchored.', [Ord(Edge)]));
      Check(DeformationMap.DebugFixedTopBlendAt(MovableX, MovableY) > 0.99,
        Format('Opposite edge %d was not movable.', [Ord(Edge)]));
      Check(DeformationMap.DebugFixedTopBlendAt(TangentBoundaryX,
        TangentBoundaryY) > 0.25,
        Format('Tangent boundary %d stopped changing too early.', [Ord(Edge)]));
      Check(DeformationMap.DebugFixedTopBlendAt(TangentBoundaryX,
        TangentBoundaryY) < 0.75,
        Format('Tangent boundary %d reached the free edge too early.',
        [Ord(Edge)]));
    end;
  finally
    DeformationMap.Free;
    Contour.Free;
  end;
end;

procedure CheckDeepSkirtMapping;
const
  IMAGE_SIZE = 512;
  MOVEMENT_SCALE = (IMAGE_SIZE - 1) / 1499;
  POINTS: array[0..17, 0..1] of Double = (
    (0.41840279, 0.5998264), (0.31597221, 0.6796875),
    (0.26302084, 0.77604169), (0.25434029, 0.8263889),
    (0.21527778, 0.86197919), (0.26475695, 0.91145831),
    (0.38802084, 0.96527779), (0.49565971, 0.98697919),
    (0.63628471, 0.94878471), (0.73524308, 0.90711808),
    (0.80555558, 0.8498264), (0.76909721, 0.77777779),
    (0.74652779, 0.73003471), (0.65538192, 0.73784721),
    (0.60677081, 0.6657986), (0.58246529, 0.60243058),
    (0.5529514, 0.59375), (0.48524305, 0.63194442));
  KINDS: array[0..17] of TShakeVertexKind = (
    svkSmooth, svkSmooth, svkSmooth, svkSmooth, svkSmooth, svkSmooth,
    svkSmooth, svkSmooth, svkSmooth, svkSmooth, svkCorner, svkSmooth,
    svkSmooth, svkSmooth, svkSmooth, svkSmooth, svkSmooth, svkSmooth);
var
  AxisLengthSquared: Double;
  AxisX: Double;
  AxisY: Double;
  Blend: Double;
  BX: Double;
  BY: Double;
  Contour: TShakeCurve;
  DeformationMap: TShakeDeformationMap;
  Determinant: Double;
  ErrorText: string;
  I: Integer;
  Inverse11: Double;
  Inverse12: Double;
  Inverse21: Double;
  Inverse22: Double;
  Jacobian: Double;
  M11: Double;
  M12: Double;
  M21: Double;
  M22: Double;
  Mapped: TPointF;
  MappedX: TPointF;
  MappedY: TPointF;
  OriginProjection: Double;
  X: Integer;
  Y: Integer;

  function IsInsideContour(const Point: TPointF): Boolean;
  var
    LocalI: Integer;
    LocalJ: Integer;
  begin
    Result := False;
    LocalJ := Contour.Count - 1;
    for LocalI := 0 to Contour.Count - 1 do
    begin
      if ((Contour[LocalI].Position.Y > Point.Y / (IMAGE_SIZE - 1)) <>
        (Contour[LocalJ].Position.Y > Point.Y / (IMAGE_SIZE - 1))) and
        (Point.X / (IMAGE_SIZE - 1) <
        (Contour[LocalJ].Position.X - Contour[LocalI].Position.X) *
        (Point.Y / (IMAGE_SIZE - 1) - Contour[LocalI].Position.Y) /
        (Contour[LocalJ].Position.Y - Contour[LocalI].Position.Y) +
        Contour[LocalI].Position.X) then
        Result := not Result;
      LocalJ := LocalI;
    end;
  end;

  function MapPoint(LocalX, LocalY: Integer): TPointF;
  var
    SampleX: Double;
    SampleY: Double;
  begin
    Blend := DeformationMap.DebugFixedTopBlendAt(LocalX, LocalY);
    SampleX := Inverse11 * (LocalX - BX) +
      Inverse12 * (LocalY - BY);
    SampleY := Inverse21 * (LocalX - BX) +
      Inverse22 * (LocalY - BY);
    Result.X := LocalX + (SampleX - LocalX) * Blend;
    Result.Y := LocalY + (SampleY - LocalY) * Blend;
  end;
begin
  Contour := TShakeCurve.Create;
  DeformationMap := TShakeDeformationMap.Create;
  try
    for I := 0 to High(POINTS) do
      Contour.AddVertex(PointF(POINTS[I, 0], POINTS[I, 1]), KINDS[I]);
    Contour.Closed := True;
    Check(DeformationMap.Build(IMAGE_SIZE, IMAGE_SIZE, Contour, nil,
      ErrorText), ErrorText);
    AxisX := (POINTS[10, 0] - POINTS[4, 0]) * (IMAGE_SIZE - 1);
    AxisY := (POINTS[10, 1] - POINTS[4, 1]) * (IMAGE_SIZE - 1);
    AxisLengthSquared := Sqr(AxisX) + Sqr(AxisY);
    M11 := 1;
    M12 := 0;
    M21 := ((-278 + 309) * MOVEMENT_SCALE) * AxisX /
      AxisLengthSquared;
    M22 := 1 + ((-278 + 309) * MOVEMENT_SCALE) * AxisY /
      AxisLengthSquared;
    OriginProjection :=
      (POINTS[4, 0] * (IMAGE_SIZE - 1) * AxisX +
      POINTS[4, 1] * (IMAGE_SIZE - 1) * AxisY) / AxisLengthSquared;
    BX := 0;
    BY := -309 * MOVEMENT_SCALE -
      ((-278 + 309) * MOVEMENT_SCALE) * OriginProjection;
    Determinant := M11 * M22 - M12 * M21;
    Inverse11 := M22 / Determinant;
    Inverse12 := -M12 / Determinant;
    Inverse21 := -M21 / Determinant;
    Inverse22 := M11 / Determinant;
    for Y := 220 to IMAGE_SIZE - 2 do
      for X := 80 to 430 do
      begin
        Mapped := MapPoint(X, Y);
        if not IsInsideContour(Mapped) then
          Continue;
        MappedX := MapPoint(X + 1, Y);
        MappedY := MapPoint(X, Y + 1);
        Jacobian := (MappedX.X - Mapped.X) * (MappedY.Y - Mapped.Y) -
          (MappedY.X - Mapped.X) * (MappedX.Y - Mapped.Y);
        Check(Jacobian >= 0,
          Format('Deep skirt mapping reversed at %d,%d: %.6f',
          [X, Y, Jacobian]));
      end;
  finally
    DeformationMap.Free;
    Contour.Free;
  end;
end;
{$ENDIF}

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
  HasAntialiasedBoundary: Boolean;
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
{$IFDEF DEBUG}
  CheckFullFrameBend;
  CheckFixedEdgeBlendMaps;
  CheckDeepSkirtMapping;
{$ENDIF}
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
      tbsLegacy, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.35, 0.38,
      0.0, 0.0, 2.0, 0.0, 0.0,
      IsFullFrameClothRange(OuterContour), False, ErrorText) then
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
    GripTargets[0] := PointF(GripOrigins[0].X + 3 / 1023,
      GripOrigins[0].Y);
    GripTargets[1] := PointF(GripOrigins[1].X + 3 / 1023,
      GripOrigins[1].Y);
    if not DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], GripOrigins, GripTargets, GripEnabled,
      tbsLegacy, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.35, 0.38,
      0.0, 0.0, 2.0, 0.0, 0.0,
      False, True, ErrorText) then
      raise Exception.Create(ErrorText);
    PixelOffset := (NativeInt(512) * Source.Width + 76) * 4;
    Check(PCardinal(@DestinationRgba[PixelOffset])^ =
      PCardinal(@SourceRgba[PixelOffset])^,
      'Tight shake selection changed a neighboring outside pixel.');
    GripTargets[0] := PointF(0.28, 0.35);
    GripTargets[1] := PointF(0.72, 0.3);
    FillChar(SourceRgba[0], Length(SourceRgba), 255);
    FullFrameEnabled[0] := True;
    FullFrameEnabled[1] := False;
    FullFrameOrigins[0] := PointF(0, 0);
    FullFrameTargets[0] := PointF(0.25, 0.25);
    FullFrameOrigins[1] := PointF(0, 0);
    FullFrameTargets[1] := PointF(0, 0);
    if not DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], FullFrameOrigins, FullFrameTargets,
      FullFrameEnabled, tbsLegacy, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0,
      0.35, 0.38, 0.0,
      0.0, 2.0, 0.0, 0.0,
      True, False, ErrorText) then
      raise Exception.Create(ErrorText);
    if DestinationRgba[3] <> 0 then
      raise Exception.Create('Full-frame vacated area was not transparent.');
    FullFrameEnabled[0] := False;
    if not DeformationMap.ApplyGripRgba(@SourceRgba[0],
      @DestinationRgba[0], FullFrameOrigins, FullFrameTargets,
      FullFrameEnabled, tbsLegacy, 0.0, 0.0, 0.0, 0.0, 0.8, 1.0, 1.0,
      0.35, 0.38, 0.0,
      0.0, 2.0, 0.0, 0.0,
      True, False, ErrorText) then
      raise Exception.Create(ErrorText);
    Check(DestinationRgba[3] = 0,
      'Full-frame shrink did not create a transparent margin.');
    PixelOffset := (NativeInt(Source.Height div 2) * Source.Width +
      Source.Width div 2) * 4;
    Check(DestinationRgba[PixelOffset + 3] = 255,
      'Full-frame shrink cleared the image center.');
    HasAntialiasedBoundary := False;
    for X := 0 to Source.Width - 1 do
    begin
      PixelOffset := (NativeInt(Source.Height div 2) * Source.Width + X) * 4;
      if (DestinationRgba[PixelOffset + 3] > 0) and
        (DestinationRgba[PixelOffset + 3] < 255) then
      begin
        HasAntialiasedBoundary := True;
        Break;
      end;
    end;
    Check(HasAntialiasedBoundary,
      'Full-frame shrink boundary was clipped without alpha interpolation.');
    StartedAt := GetTickCount64;
    for FrameIndex := 0 to 29 do
      if not DeformationMap.ApplyGripRgba(@SourceRgba[0],
        @DestinationRgba[0], GripOrigins, GripTargets,
        GripEnabled, tbsLegacy, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0,
        0.35, 0.38, 0.25,
        15.0, 2.0, 2 * Pi * FrameIndex / 60, 17.0,
        True, False, ErrorText) then
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
