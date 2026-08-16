unit Shake_PPP_StaticDeformer;

interface

uses
  System.Types,
  Vcl.Graphics,
  Shake_PPP_CurveModel;

function IsFullFrameClothRange(OuterContour: TShakeCurve): Boolean;

type
  TShakeDeformationMap = class
  private
    FActiveBottom: Integer;
    FActiveLeft: Integer;
    FActiveRight: Integer;
    FActiveTop: Integer;
    FFixedTopBlend: TArray<Single>;
    FFixedTopLeft: TPointF;
    FFixedTopRight: TPointF;
    FFixedTopValid: Boolean;
    FFixedEdge: TTurnOverFixedEdge;
    FCoverage: TArray<Single>;
    FTightCoverage: TArray<Single>;
    FHeight: Integer;
    FLastTimingLog: UInt64;
    FWeights: TArray<Single>;
    FWidth: Integer;
  public
    procedure Clear;
    function Build(Width, Height: Integer; OuterContour,
      CenterContour: TShakeCurve; out ErrorText: string): Boolean; overload;
    function Build(Width, Height: Integer; OuterContour,
      CenterContour: TShakeCurve; FixedEdge: TTurnOverFixedEdge;
      out ErrorText: string): Boolean; overload;
    function Apply(Source, Destination: TBitmap;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
    function ApplyGripPreview(Source, Destination: TBitmap;
      const OriginalPositions, TargetPositions: TShakeGripPositions;
      const Enabled: TShakeGripEnabled; FullFrameMode: Boolean;
      out ErrorText: string): Boolean;
    function ApplyGripRgba(Source, Destination: Pointer;
      const OriginalPositions, TargetPositions: TShakeGripPositions;
      const Enabled: TShakeGripEnabled; BillowStyle: TTurnOverBillowStyle;
      BillowDisplacementX, BillowDisplacementY, BillowStrength,
      GravityStrength, ShrinkRate, FoldStrength, LightingStrength,
      BacksideStrength,
      InfluenceRadius, CastShadowStrength: Double;
      RippleStrength, RippleCount, RipplePhase,
      RippleDirectionDegrees: Double; FullFrameMode,
      TightPartialCoverage: Boolean;
      out ErrorText: string): Boolean;
    function ApplyRgba(Source, Destination: Pointer;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
    function ApplyVariableOuterRgba(Source, Destination: Pointer;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean;
{$IFDEF DEBUG}
    function DebugFixedTopBlendAt(X, Y: Integer): Double;
    procedure SaveDebugCoverageBitmap(const FileName: string;
      TightPartialCoverage: Boolean);
{$ENDIF}
    property Height: Integer read FHeight;
    property Width: Integer read FWidth;
  end;

  TShakeStaticDeformer = class sealed
  public
    class function TryDeform(Source, Destination: TBitmap;
      OuterContour, CenterContour: TShakeCurve;
      DisplacementX, DisplacementY: Double;
      out ErrorText: string): Boolean; static;
  end;

implementation

uses
  System.Math,
  System.SysUtils,
  System.Threading,
  Winapi.Windows
{$IFDEF DEBUG}
  , Shake_PPP_DebugLog
{$ENDIF}
  ;

const
  CURVE_SAMPLES_PER_SEGMENT = 12;
  GRIP_BACKSIDE_DARKENING = 0.08;
  GRIP_BACKSIDE_DESATURATION = 0.28;
  GRIP_CAST_SHADOW_RADIUS = 0.025;
  GRIP_FOLD_SHADOW_GAIN = 0.70;
  GRIP_LIFT_LIGHT_GAIN = 0.25;
  GRIP_MAX_FORESHORTENING = 0.22;
  GRIP_PREVIEW_BACKSIDE_STRENGTH = 0.35;
  GRIP_PREVIEW_CAST_SHADOW_STRENGTH = 0.25;
  GRIP_FORESHORTENING_GAIN = 0.45;
  GRIP_WEIGHT_LUT_SIZE = 4096;
  GRIP_WEIGHT_MAX_DISTANCE_RATIO = 8.0;
  FLUTTER_DEPTH_LUT_SIZE = 256;
  FLUTTER_MAX_NORMAL_STEP = 0.35;
  FIXED_TOP_GRID_SIZE = 8;
  MASK_GRID_SIZE = 4;
  PARTIAL_SELECTION_MARGIN_RATIO = 0.0064;
  PARTIAL_TIGHT_SELECTION_MARGIN_PIXELS = 2;
  VARIABLE_OUTER_MOTION_RATIO = 0.35;

type
  TBoundarySegment = record
    Point0: TPointF;
    Point1: TPointF;
  end;
  TBoundarySegments = TArray<TBoundarySegment>;
  TDoubleArray = array of Double;
  TBitmapRows = array of PByte;
  PByteRow = ^TByteRow;
  TByteRow = array[0..268435455] of Byte;

var
  GripWeightLookup: array[0..GRIP_WEIGHT_LUT_SIZE] of Single;

procedure InitializeGripWeightLookup;
var
  I: Integer;
begin
  for I := 0 to GRIP_WEIGHT_LUT_SIZE do
    GripWeightLookup[I] := Exp(-2 * GRIP_WEIGHT_MAX_DISTANCE_RATIO *
      I / GRIP_WEIGHT_LUT_SIZE);
end;

function LookupGripWeight(DistanceSquared,
  InverseRadiusSquared: Double): Double; inline;
var
  Fraction: Double;
  Index: Integer;
  ScaledDistance: Double;
begin
  ScaledDistance := DistanceSquared * InverseRadiusSquared *
    GRIP_WEIGHT_LUT_SIZE / GRIP_WEIGHT_MAX_DISTANCE_RATIO;
  if ScaledDistance >= GRIP_WEIGHT_LUT_SIZE then
    Exit(0);
  Index := Trunc(ScaledDistance);
  Fraction := ScaledDistance - Index;
  Result := GripWeightLookup[Index] * (1 - Fraction) +
    GripWeightLookup[Index + 1] * Fraction;
end;

function IsFullFrameClothRange(OuterContour: TShakeCurve): Boolean;
const
  EDGE_THRESHOLD = 0.015;
var
  I: Integer;
  MaximumX: Double;
  MaximumY: Double;
  MinimumX: Double;
  MinimumY: Double;
begin
  Result := False;
  if (OuterContour = nil) or not OuterContour.Closed or
    (OuterContour.Count < 3) then
    Exit;
  MinimumX := 1;
  MinimumY := 1;
  MaximumX := 0;
  MaximumY := 0;
  for I := 0 to OuterContour.Count - 1 do
  begin
    MinimumX := Min(MinimumX, OuterContour[I].Position.X);
    MinimumY := Min(MinimumY, OuterContour[I].Position.Y);
    MaximumX := Max(MaximumX, OuterContour[I].Position.X);
    MaximumY := Max(MaximumY, OuterContour[I].Position.Y);
  end;
  Result := (MinimumX <= EDGE_THRESHOLD) and
    (MinimumY <= EDGE_THRESHOLD) and
    (MaximumX >= 1 - EDGE_THRESHOLD) and
    (MaximumY >= 1 - EDGE_THRESHOLD);
end;

function CubicPoint(const Point0, Control1, Control2, Point3: TPointF;
  T: Double): TPointF;
var
  OneMinusT: Double;
begin
  OneMinusT := 1 - T;
  Result.X := Sqr(OneMinusT) * OneMinusT * Point0.X +
    3 * Sqr(OneMinusT) * T * Control1.X +
    3 * OneMinusT * Sqr(T) * Control2.X + Sqr(T) * T * Point3.X;
  Result.Y := Sqr(OneMinusT) * OneMinusT * Point0.Y +
    3 * Sqr(OneMinusT) * T * Control1.Y +
    3 * OneMinusT * Sqr(T) * Control2.Y + Sqr(T) * T * Point3.Y;
end;

procedure CurveControlPoints(Curve: TShakeCurve; SegmentIndex: Integer;
  out Point0, Control1, Control2, Point3: TPointF);
var
  A: TShakeCurveVertex;
  B: TShakeCurveVertex;
  BIndex: Integer;
  NextPosition: TPointF;
  PreviousPosition: TPointF;
begin
  BIndex := (SegmentIndex + 1) mod Curve.Count;
  A := Curve[SegmentIndex];
  B := Curve[BIndex];
  Point0 := A.Position;
  Point3 := B.Position;
  Control1 := Point0;
  Control2 := Point3;
  if A.Kind = svkSmooth then
  begin
    if SegmentIndex > 0 then
      PreviousPosition := Curve[SegmentIndex - 1].Position
    else
      PreviousPosition := Curve[Curve.Count - 1].Position;
    Control1.X := Point0.X + (Point3.X - PreviousPosition.X) / 6;
    Control1.Y := Point0.Y + (Point3.Y - PreviousPosition.Y) / 6;
  end;
  if B.Kind = svkSmooth then
  begin
    if BIndex + 1 < Curve.Count then
      NextPosition := Curve[BIndex + 1].Position
    else
      NextPosition := Curve[0].Position;
    Control2.X := Point3.X - (NextPosition.X - Point0.X) / 6;
    Control2.Y := Point3.Y - (NextPosition.Y - Point0.Y) / 6;
  end;
end;

function FlattenCurve(Curve: TShakeCurve): TArray<TPointF>;
var
  Control1: TPointF;
  Control2: TPointF;
  I: Integer;
  Point0: TPointF;
  Point3: TPointF;
  SampleIndex: Integer;
begin
  SetLength(Result, Curve.Count * CURVE_SAMPLES_PER_SEGMENT);
  for I := 0 to Curve.Count - 1 do
  begin
    CurveControlPoints(Curve, I, Point0, Control1, Control2, Point3);
    for SampleIndex := 0 to CURVE_SAMPLES_PER_SEGMENT - 1 do
      Result[I * CURVE_SAMPLES_PER_SEGMENT + SampleIndex] := CubicPoint(
        Point0, Control1, Control2, Point3,
        SampleIndex / CURVE_SAMPLES_PER_SEGMENT);
  end;
end;

function PointInPolygon(const Polygon: TArray<TPointF>;
  X, Y: Double): Boolean;
var
  I: Integer;
  J: Integer;
begin
  Result := False;
  J := High(Polygon);
  for I := 0 to High(Polygon) do
  begin
    if ((Polygon[I].Y > Y) <> (Polygon[J].Y > Y)) and
      (X < (Polygon[J].X - Polygon[I].X) * (Y - Polygon[I].Y) /
      (Polygon[J].Y - Polygon[I].Y) + Polygon[I].X) then
      Result := not Result;
    J := I;
  end;
end;

function DistanceToPolygon(const Polygon: TArray<TPointF>;
  X, Y, Aspect: Double): Double;
var
  ClosestX: Double;
  ClosestY: Double;
  DX: Double;
  DY: Double;
  I: Integer;
  J: Integer;
  LengthSquared: Double;
  Projection: Double;
begin
  Result := MaxDouble;
  J := High(Polygon);
  for I := 0 to High(Polygon) do
  begin
    DX := (Polygon[I].X - Polygon[J].X) * Aspect;
    DY := Polygon[I].Y - Polygon[J].Y;
    LengthSquared := DX * DX + DY * DY;
    if LengthSquared > 0 then
      Projection := EnsureRange((((X - Polygon[J].X) * Aspect) * DX +
        (Y - Polygon[J].Y) * DY) / LengthSquared, 0.0, 1.0)
    else
      Projection := 0;
    ClosestX := Polygon[J].X + Projection *
      (Polygon[I].X - Polygon[J].X);
    ClosestY := Polygon[J].Y + Projection *
      (Polygon[I].Y - Polygon[J].Y);
    Result := Min(Result, Sqrt(Sqr((X - ClosestX) * Aspect) +
      Sqr(Y - ClosestY)));
    J := I;
  end;
end;

function MaskValue(const OuterPolygon, CenterPolygon: TArray<TPointF>;
  X, Y, Aspect: Double): Double;
var
  CenterDistance: Double;
  OuterDistance: Double;
begin
  if not PointInPolygon(OuterPolygon, X, Y) then
    Exit(0);
  if PointInPolygon(CenterPolygon, X, Y) then
    Exit(1);
  OuterDistance := DistanceToPolygon(OuterPolygon, X, Y, Aspect);
  CenterDistance := DistanceToPolygon(CenterPolygon, X, Y, Aspect);
  if OuterDistance + CenterDistance <= 1.0E-9 then
    Exit(0);
  Result := OuterDistance / (OuterDistance + CenterDistance);
  // Smoothstep removes a visible change of slope at both boundaries.
  Result := Result * Result * (3 - 2 * Result);
end;

function InterpolatedMask(const Mask: TDoubleArray; GridWidth, GridHeight,
  GridSize, X, Y: Integer): Double;
var
  FX: Double;
  FY: Double;
  GridX: Double;
  GridY: Double;
  X0: Integer;
  X1: Integer;
  Y0: Integer;
  Y1: Integer;
begin
  GridX := X / GridSize;
  GridY := Y / GridSize;
  X0 := EnsureRange(Trunc(GridX), 0, GridWidth - 1);
  Y0 := EnsureRange(Trunc(GridY), 0, GridHeight - 1);
  X1 := Min(X0 + 1, GridWidth - 1);
  Y1 := Min(Y0 + 1, GridHeight - 1);
  FX := GridX - X0;
  FY := GridY - Y0;
  Result := (Mask[Y0 * GridWidth + X0] * (1 - FX) +
    Mask[Y0 * GridWidth + X1] * FX) * (1 - FY) +
    (Mask[Y1 * GridWidth + X0] * (1 - FX) +
    Mask[Y1 * GridWidth + X1] * FX) * FY;
end;

function OuterOnlyMaskValue(const OuterPolygon: TArray<TPointF>;
  X, Y, Aspect: Double): Double;
const
  EDGE_FADE_DISTANCE = 0.035;
begin
  if not PointInPolygon(OuterPolygon, X, Y) then
    Exit(0);
  Result := EnsureRange(DistanceToPolygon(OuterPolygon, X, Y, Aspect) /
    EDGE_FADE_DISTANCE, 0.0, 1.0);
  Result := Result * Result * (3 - 2 * Result);
end;

{$IFDEF DEBUG}
procedure DebugLogCurveCoordinates(const CurveName: string;
  Curve: TShakeCurve; const Polygon: TArray<TPointF>;
  Width, Height: Integer);
var
  I: Integer;
  MaximumX: Double;
  MaximumY: Double;
  MinimumX: Double;
  MinimumY: Double;
  Vertex: TShakeCurveVertex;
begin
  for I := 0 to Curve.Count - 1 do
  begin
    Vertex := Curve[I];
    Shake_PPP_DebugLog.DebugLog(Format(
      'Deformation curve vertex: curve=%s index=%d normalized=(%.8f,%.8f) image=(%.3f,%.3f).',
      [CurveName, I, Vertex.Position.X, Vertex.Position.Y,
       Vertex.Position.X * Max(1, Width - 1),
       Vertex.Position.Y * Max(1, Height - 1)]));
  end;

  MinimumX := MaxDouble;
  MinimumY := MaxDouble;
  MaximumX := -MaxDouble;
  MaximumY := -MaxDouble;
  for I := 0 to High(Polygon) do
  begin
    MinimumX := Min(MinimumX, Polygon[I].X);
    MinimumY := Min(MinimumY, Polygon[I].Y);
    MaximumX := Max(MaximumX, Polygon[I].X);
    MaximumY := Max(MaximumY, Polygon[I].Y);
  end;
  Shake_PPP_DebugLog.DebugLog(Format(
    'Deformation curve bounds: curve=%s normalized=(%.8f,%.8f)-(%.8f,%.8f) image=(%.3f,%.3f)-(%.3f,%.3f).',
    [CurveName, MinimumX, MinimumY, MaximumX, MaximumY,
     MinimumX * Max(1, Width - 1), MinimumY * Max(1, Height - 1),
     MaximumX * Max(1, Width - 1), MaximumY * Max(1, Height - 1)]));
end;
{$ENDIF}

procedure TShakeDeformationMap.Clear;
begin
  FCoverage := nil;
  FTightCoverage := nil;
  FFixedTopBlend := nil;
  FWeights := nil;
  FWidth := 0;
  FHeight := 0;
  FActiveLeft := 0;
  FActiveTop := 0;
  FActiveRight := -1;
  FActiveBottom := -1;
  FFixedTopLeft := PointF(0, 0);
  FFixedTopRight := PointF(0, 0);
  FFixedTopValid := False;
  FFixedEdge := tfeTop;
  FLastTimingLog := 0;
end;

function TShakeDeformationMap.Build(Width, Height: Integer;
  OuterContour, CenterContour: TShakeCurve;
  out ErrorText: string): Boolean;
begin
  Result := Build(Width, Height, OuterContour, CenterContour, tfeTop,
    ErrorText);
end;

function TShakeDeformationMap.Build(Width, Height: Integer;
  OuterContour, CenterContour: TShakeCurve;
  FixedEdge: TTurnOverFixedEdge;
  out ErrorText: string): Boolean;
var
  Aspect: Double;
  CenterPolygon: TArray<TPointF>;
  ExpandedCoverage: TArray<Single>;
  FixedTopGrid: TDoubleArray;
  FixedTopGridHeight: Integer;
  FixedTopGridWidth: Integer;
  FixedTopGridX: Integer;
  FixedTopGridY: Integer;
  FixedTopSegments: TBoundarySegments;
  FixedTopPixelX: Integer;
  FixedTopPixelY: Integer;
  FixedTopStep: Integer;
  FixedTopStepCount: Integer;
  GridHeight: Integer;
  GridWidth: Integer;
  GridX: Integer;
  GridY: Integer;
  InsideOuter: Boolean;
  Mask: TDoubleArray;
  NormalizedX: Double;
  NormalizedY: Double;
  LowerBoundarySegments: TBoundarySegments;
  OppositeBoundaryValid: Boolean;
  OppositeEdge: TTurnOverFixedEdge;
  OppositeFirstIndex: Integer;
  OppositePathStep: Integer;
  OppositeSecondIndex: Integer;
  OuterPolygon: TArray<TPointF>;
  UpperLeftIndex: Integer;
  UpperPathStep: Integer;
  UpperRightIndex: Integer;
  SelectionMarginPixels: Integer;
  AffectedBottom: Integer;
  AffectedLeft: Integer;
  AffectedRight: Integer;
  AffectedTop: Integer;
  ScreenY: Integer;
  UseCenterContour: Boolean;
{$IFDEF DEBUG}
  AffectedCount: NativeInt;
  StartedAt: UInt64;
{$ENDIF}
  X: Integer;
  Y: Integer;
  Weight: Double;

  function DistanceSquaredToBoundary(const Segments: TBoundarySegments;
    NormalizedPixelX, NormalizedPixelY: Double): Double;
  var
    ClosestX: Double;
    ClosestY: Double;
    DistanceSquared: Double;
    DX: Double;
    DY: Double;
    I: Integer;
    LengthSquared: Double;
    Projection: Double;
  begin
    Result := MaxDouble;
    for I := 0 to High(Segments) do
    begin
      DX := (Segments[I].Point1.X - Segments[I].Point0.X) *
        Max(1, Width - 1);
      DY := (Segments[I].Point1.Y - Segments[I].Point0.Y) *
        Max(1, Height - 1);
      LengthSquared := DX * DX + DY * DY;
      if LengthSquared > 1.0E-9 then
        Projection := EnsureRange(
          (((NormalizedPixelX - Segments[I].Point0.X) *
          Max(1, Width - 1)) * DX +
          ((NormalizedPixelY - Segments[I].Point0.Y) *
          Max(1, Height - 1)) * DY) / LengthSquared, 0.0, 1.0)
      else
        Projection := 0;
      ClosestX := Segments[I].Point0.X +
        (Segments[I].Point1.X - Segments[I].Point0.X) * Projection;
      ClosestY := Segments[I].Point0.Y +
        (Segments[I].Point1.Y - Segments[I].Point0.Y) * Projection;
      DistanceSquared := Sqr((NormalizedPixelX - ClosestX) *
        Max(1, Width - 1)) + Sqr((NormalizedPixelY - ClosestY) *
        Max(1, Height - 1));
      Result := Min(Result, DistanceSquared);
    end;
  end;

  procedure DilateCoverage(const SourceCoverage: TArray<Single>;
    MarginPixels: Integer; out DestinationCoverage: TArray<Single>);
  var
    HorizontalCoverage: TArray<Single>;
    LocalWindowAddIndex: Integer;
    LocalWindowCount: Integer;
    LocalWindowRemoveIndex: Integer;
    LocalX: Integer;
    LocalY: Integer;
  begin
    SetLength(HorizontalCoverage, Width * Height);
    SetLength(DestinationCoverage, Width * Height);
    for LocalY := 0 to Height - 1 do
    begin
      LocalWindowCount := 0;
      for LocalWindowAddIndex := 0 to Min(MarginPixels, Width - 1) do
        if SourceCoverage[LocalY * Width + LocalWindowAddIndex] > 0 then
          Inc(LocalWindowCount);
      for LocalX := 0 to Width - 1 do
      begin
        HorizontalCoverage[LocalY * Width + LocalX] :=
          Ord(LocalWindowCount > 0);
        LocalWindowRemoveIndex := LocalX - MarginPixels;
        if (LocalWindowRemoveIndex >= 0) and
          (SourceCoverage[LocalY * Width + LocalWindowRemoveIndex] > 0) then
          Dec(LocalWindowCount);
        LocalWindowAddIndex := LocalX + MarginPixels + 1;
        if (LocalWindowAddIndex < Width) and
          (SourceCoverage[LocalY * Width + LocalWindowAddIndex] > 0) then
          Inc(LocalWindowCount);
      end;
    end;
    for LocalX := 0 to Width - 1 do
    begin
      LocalWindowCount := 0;
      for LocalWindowAddIndex := 0 to Min(MarginPixels, Height - 1) do
        if HorizontalCoverage[LocalWindowAddIndex * Width + LocalX] > 0 then
          Inc(LocalWindowCount);
      for LocalY := 0 to Height - 1 do
      begin
        DestinationCoverage[LocalY * Width + LocalX] :=
          Ord(LocalWindowCount > 0);
        LocalWindowRemoveIndex := LocalY - MarginPixels;
        if (LocalWindowRemoveIndex >= 0) and
          (HorizontalCoverage[LocalWindowRemoveIndex * Width + LocalX] > 0) then
          Dec(LocalWindowCount);
        LocalWindowAddIndex := LocalY + MarginPixels + 1;
        if (LocalWindowAddIndex < Height) and
          (HorizontalCoverage[LocalWindowAddIndex * Width + LocalX] > 0) then
          Inc(LocalWindowCount);
      end;
    end;
  end;

  function FixedTopBlendAt(NormalizedPixelX,
    NormalizedPixelY: Double): Double;
  var
    MinimumLowerDistanceSquared: Double;
    MinimumTopDistanceSquared: Double;
    TopDistance: Double;
    LowerDistance: Double;
  begin
    if not FFixedTopValid then
      Exit(1);
    MinimumTopDistanceSquared := DistanceSquaredToBoundary(FixedTopSegments,
      NormalizedPixelX, NormalizedPixelY);
    MinimumLowerDistanceSquared := DistanceSquaredToBoundary(
      LowerBoundarySegments, NormalizedPixelX, NormalizedPixelY);
    if MinimumTopDistanceSquared <= 2 then
      Exit(0);
    if MinimumLowerDistanceSquared <= 2 then
      Exit(1);
    if (MinimumTopDistanceSquared = MaxDouble) or
      (MinimumLowerDistanceSquared = MaxDouble) then
      Exit(1);
    TopDistance := Sqrt(MinimumTopDistanceSquared);
    LowerDistance := Sqrt(MinimumLowerDistanceSquared);
    Result := TopDistance / Max(1.0E-9, TopDistance + LowerDistance);
    { Normalize the attachment over the whole cloth depth.  A fixed pixel
      radius can force a large grip motion through a narrow transition and
      reverse the sampling coordinates.  The opposite-boundary distance keeps
      the transition broad while still reaching exactly 0 and 1 at the fixed
      and movable edges. }
    Result := Result * Result * (3 - 2 * Result);
  end;
begin
  Result := False;
  ErrorText := '';
  Clear;
  FFixedEdge := FixedEdge;
  if (Width <= 0) or (Height <= 0) then
  begin
    ErrorText := 'NO_IMAGE';
    Exit;
  end;
  if (OuterContour = nil) or not OuterContour.Closed or
    (OuterContour.Count < 3) then
  begin
    ErrorText := 'OUTER_NOT_CLOSED';
    Exit;
  end;
  OuterPolygon := FlattenCurve(OuterContour);
  FFixedTopValid := TryGetFixedBoundary(OuterContour, FixedEdge,
    UpperLeftIndex, UpperRightIndex, UpperPathStep);
  case FixedEdge of
    tfeTop: OppositeEdge := tfeBottom;
    tfeBottom: OppositeEdge := tfeTop;
    tfeLeft: OppositeEdge := tfeRight;
  else
    OppositeEdge := tfeLeft;
  end;
  OppositeBoundaryValid := TryGetFixedBoundary(OuterContour, OppositeEdge,
    OppositeFirstIndex, OppositeSecondIndex, OppositePathStep);
  SetLength(FixedTopSegments, Length(OuterPolygon));
  SetLength(LowerBoundarySegments, Length(OuterPolygon));
  AffectedLeft := 0;
  AffectedRight := 0;
  for X := 0 to High(OuterPolygon) do
  begin
    Y := (X + 1) mod Length(OuterPolygon);
    if FFixedTopValid and
      IsVertexOnCurvePath(X div CURVE_SAMPLES_PER_SEGMENT,
        UpperLeftIndex, UpperRightIndex, UpperPathStep,
        OuterContour.Count) and
      IsVertexOnCurvePath(((X div CURVE_SAMPLES_PER_SEGMENT) + 1) mod
        OuterContour.Count, UpperLeftIndex, UpperRightIndex, UpperPathStep,
        OuterContour.Count) then
    begin
      FixedTopSegments[AffectedLeft].Point0 := OuterPolygon[X];
      FixedTopSegments[AffectedLeft].Point1 := OuterPolygon[Y];
      Inc(AffectedLeft);
    end
    else if OppositeBoundaryValid and
      IsVertexOnCurvePath(X div CURVE_SAMPLES_PER_SEGMENT,
        OppositeFirstIndex, OppositeSecondIndex, OppositePathStep,
        OuterContour.Count) and
      IsVertexOnCurvePath(((X div CURVE_SAMPLES_PER_SEGMENT) + 1) mod
        OuterContour.Count, OppositeFirstIndex, OppositeSecondIndex,
        OppositePathStep, OuterContour.Count) then
    begin
      LowerBoundarySegments[AffectedRight].Point0 := OuterPolygon[X];
      LowerBoundarySegments[AffectedRight].Point1 := OuterPolygon[Y];
      Inc(AffectedRight);
    end;
  end;
  SetLength(FixedTopSegments, AffectedLeft);
  SetLength(LowerBoundarySegments, AffectedRight);
  if FFixedTopValid then
  begin
    FFixedTopLeft := OuterContour[UpperLeftIndex].Position;
    FFixedTopRight := OuterContour[UpperRightIndex].Position;
  end;
{$IFDEF DEBUG}
  if FFixedTopValid then
    DebugLog(Format(
      'Partial fixed edge: edge=%d first=(%.4f,%.4f) second=(%.4f,%.4f) pathStep=%d oppositeValid=%s.',
      [Ord(FixedEdge), FFixedTopLeft.X, FFixedTopLeft.Y, FFixedTopRight.X,
       FFixedTopRight.Y, UpperPathStep,
       BoolToStr(OppositeBoundaryValid, True)]));
{$ENDIF}
  UseCenterContour := (CenterContour <> nil) and CenterContour.Closed and
    (CenterContour.Count >= 3);
  if UseCenterContour then
    CenterPolygon := FlattenCurve(CenterContour)
  else
    CenterPolygon := nil;
  Aspect := Width / Height;
  SelectionMarginPixels := EnsureRange(Round(
    Max(Width, Height) * PARTIAL_SELECTION_MARGIN_RATIO), 2, 12);
  GridWidth := (Width + MASK_GRID_SIZE - 1) div MASK_GRID_SIZE + 1;
  GridHeight := (Height + MASK_GRID_SIZE - 1) div MASK_GRID_SIZE + 1;
  SetLength(Mask, GridWidth * GridHeight);
  FixedTopGridWidth := (Width + FIXED_TOP_GRID_SIZE - 1) div
    FIXED_TOP_GRID_SIZE + 1;
  FixedTopGridHeight := (Height + FIXED_TOP_GRID_SIZE - 1) div
    FIXED_TOP_GRID_SIZE + 1;
  SetLength(FixedTopGrid, FixedTopGridWidth * FixedTopGridHeight);
  AffectedLeft := Width;
  AffectedTop := Height;
  AffectedRight := -1;
  AffectedBottom := -1;
{$IFDEF DEBUG}
  StartedAt := GetTickCount64;
  DebugLogCurveCoordinates('outer', OuterContour, OuterPolygon,
    Width, Height);
  if UseCenterContour then
    DebugLogCurveCoordinates('center', CenterContour, CenterPolygon,
      Width, Height);
  AffectedCount := 0;
{$ENDIF}
  for GridY := 0 to GridHeight - 1 do
    for GridX := 0 to GridWidth - 1 do
    begin
      if UseCenterContour then
        Mask[GridY * GridWidth + GridX] := MaskValue(OuterPolygon,
          CenterPolygon, Min(GridX * MASK_GRID_SIZE, Width - 1) /
          Max(1, Width - 1),
          1 - Min(GridY * MASK_GRID_SIZE, Height - 1) /
          Max(1, Height - 1), Aspect)
      else
        Mask[GridY * GridWidth + GridX] := OuterOnlyMaskValue(OuterPolygon,
          Min(GridX * MASK_GRID_SIZE, Width - 1) / Max(1, Width - 1),
          1 - Min(GridY * MASK_GRID_SIZE, Height - 1) /
          Max(1, Height - 1), Aspect);
    end;
  for FixedTopGridY := 0 to FixedTopGridHeight - 1 do
    for FixedTopGridX := 0 to FixedTopGridWidth - 1 do
      FixedTopGrid[FixedTopGridY * FixedTopGridWidth + FixedTopGridX] :=
        FixedTopBlendAt(
          Min(FixedTopGridX * FIXED_TOP_GRID_SIZE, Width - 1) /
          Max(1, Width - 1),
          1 - Min(FixedTopGridY * FIXED_TOP_GRID_SIZE, Height - 1) /
          Max(1, Height - 1));
  FWidth := Width;
  FHeight := Height;
  SetLength(FCoverage, FWidth * FHeight);
  SetLength(FFixedTopBlend, FWidth * FHeight);
  SetLength(FWeights, FWidth * FHeight);
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
    begin
      Weight := InterpolatedMask(Mask, GridWidth, GridHeight,
        MASK_GRID_SIZE, X, Y);
      NormalizedX := X / Max(1, FWidth - 1);
      NormalizedY := 1 - Y / Max(1, FHeight - 1);
      InsideOuter := PointInPolygon(OuterPolygon, NormalizedX, NormalizedY);
      if not InsideOuter then
        Weight := 0;
      FCoverage[Y * FWidth + X] := Ord(InsideOuter);
      FFixedTopBlend[Y * FWidth + X] := InterpolatedMask(FixedTopGrid,
        FixedTopGridWidth, FixedTopGridHeight, FIXED_TOP_GRID_SIZE, X, Y);
      FWeights[Y * FWidth + X] := Weight;
    end;
  { Coarse interpolation is sufficient away from the seam, but the fixed
    boundary itself must remain exact.  Rasterize its sampled segments back
    into the full-resolution map, including the same two-pixel anchor width
    used by FixedTopBlendAt. }
  for X := 0 to High(FixedTopSegments) do
  begin
    FixedTopStepCount := Max(1, Ceil(Max(
      Abs(FixedTopSegments[X].Point1.X -
        FixedTopSegments[X].Point0.X) * Max(1, FWidth - 1),
      Abs(FixedTopSegments[X].Point1.Y -
        FixedTopSegments[X].Point0.Y) * Max(1, FHeight - 1))));
    for FixedTopStep := 0 to FixedTopStepCount do
    begin
      FixedTopPixelX := Round((FixedTopSegments[X].Point0.X +
        (FixedTopSegments[X].Point1.X -
        FixedTopSegments[X].Point0.X) * FixedTopStep /
        FixedTopStepCount) * Max(1, FWidth - 1));
      FixedTopPixelY := FHeight - 1 - Round(
        (FixedTopSegments[X].Point0.Y +
        (FixedTopSegments[X].Point1.Y -
        FixedTopSegments[X].Point0.Y) * FixedTopStep /
        FixedTopStepCount) * Max(1, FHeight - 1));
      for Y := Max(0, FixedTopPixelY - 1) to
        Min(FHeight - 1, FixedTopPixelY + 1) do
        for GridX := Max(0, FixedTopPixelX - 1) to
          Min(FWidth - 1, FixedTopPixelX + 1) do
          FFixedTopBlend[Y * FWidth + GridX] := 0;
    end;
  end;
  if not IsFullFrameClothRange(OuterContour) then
  begin
    { A separable binary dilation includes outlines and antialiasing just
      outside the hand-drawn contour without repeating polygon-distance work
      for every nearby pixel. }
    DilateCoverage(FCoverage, PARTIAL_TIGHT_SELECTION_MARGIN_PIXELS,
      FTightCoverage);
    DilateCoverage(FCoverage, SelectionMarginPixels, ExpandedCoverage);
    FCoverage := ExpandedCoverage;
  end;
  if Length(FTightCoverage) = 0 then
    FTightCoverage := FCoverage;
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
      if FCoverage[Y * FWidth + X] > 0 then
      begin
        ScreenY := FHeight - 1 - Y;
        AffectedLeft := Min(AffectedLeft, X);
        AffectedTop := Min(AffectedTop, ScreenY);
        AffectedRight := Max(AffectedRight, X);
        AffectedBottom := Max(AffectedBottom, ScreenY);
{$IFDEF DEBUG}
        Inc(AffectedCount);
{$ENDIF}
      end;
  FActiveLeft := AffectedLeft;
  FActiveTop := AffectedTop;
  FActiveRight := AffectedRight;
  FActiveBottom := AffectedBottom;
{$IFDEF DEBUG}
  if AffectedCount > 0 then
    Shake_PPP_DebugLog.DebugLog(Format(
      'Deformation affected bounds: image=(%d,%d)-(%d,%d) pixels=%d coordinateSpace=image-dpi-independent.',
      [AffectedLeft, AffectedTop, AffectedRight, AffectedBottom,
       AffectedCount]))
  else
    Shake_PPP_DebugLog.DebugLog(
      'Deformation affected bounds: empty coordinateSpace=image-dpi-independent.');
  Shake_PPP_DebugLog.DebugLog(Format(
    'Deformation map built: size=%dx%d grid=%dx%d elapsed=%dms.',
    [FWidth, FHeight, GridWidth, GridHeight,
     GetTickCount64 - StartedAt]));
{$ENDIF}
  Result := True;
end;

function TShakeDeformationMap.Apply(Source,
  Destination: Vcl.Graphics.TBitmap;
  DisplacementX, DisplacementY: Double;
  out ErrorText: string): Boolean;
var
  BlendWeight: Double;
  Channel: Integer;
  DestinationRows: TBitmapRows;
  DestinationRow: PByteRow;
  FX: Double;
  FY: Double;
  PixelOffset0: Integer;
  PixelOffset1: Integer;
  Row0: PByteRow;
  Row1: PByteRow;
  SourceRows: TBitmapRows;
  SourceX: Double;
  SourceY: Double;
{$IFDEF DEBUG}
  StartedAt: UInt64;
{$ENDIF}
  Value: Double;
  Weight: Double;
  WeightY: Integer;
  X: Integer;
  X0: Integer;
  X1: Integer;
  Y: Integer;
  Y0: Integer;
  Y1: Integer;
begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) or
    (Source.Width <> FWidth) or (Source.Height <> FHeight) or
    (Length(FWeights) <> FWidth * FHeight) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;
  Source.PixelFormat := pf32bit;
  Destination.PixelFormat := pf32bit;
  Destination.SetSize(Source.Width, Source.Height);
  SetLength(SourceRows, Source.Height);
  SetLength(DestinationRows, Destination.Height);
{$IFDEF DEBUG}
  StartedAt := GetTickCount64;
{$ENDIF}
  for Y := 0 to Source.Height - 1 do
  begin
    SourceRows[Y] := Source.ScanLine[Y];
    DestinationRows[Y] := Destination.ScanLine[Y];
    Move(SourceRows[Y]^, DestinationRows[Y]^, NativeInt(Source.Width) * 4);
  end;
  for Y := FActiveTop to FActiveBottom do
  begin
    DestinationRow := PByteRow(DestinationRows[Y]);
    // Use the same top-origin curve coordinate space as the AviUtl2 output.
    WeightY := FHeight - 1 - Y;
    for X := FActiveLeft to FActiveRight do
    begin
      Weight := FWeights[WeightY * FWidth + X];
      BlendWeight := Weight * Weight;
      SourceX := EnsureRange(X - DisplacementX * Weight,
        0.0, Source.Width - 1.0);
      SourceY := EnsureRange(Y - DisplacementY * Weight,
        0.0, Source.Height - 1.0);
      X0 := Trunc(SourceX);
      Y0 := Trunc(SourceY);
      X1 := Min(X0 + 1, Source.Width - 1);
      Y1 := Min(Y0 + 1, Source.Height - 1);
      FX := SourceX - X0;
      FY := SourceY - Y0;
      Row0 := PByteRow(SourceRows[Y0]);
      Row1 := PByteRow(SourceRows[Y1]);
      PixelOffset0 := X0 * 4;
      PixelOffset1 := X1 * 4;
      for Channel := 0 to 3 do
      begin
        Value := (Row0[PixelOffset0 + Channel] * (1 - FX) +
          Row0[PixelOffset1 + Channel] * FX) * (1 - FY) +
          (Row1[PixelOffset0 + Channel] * (1 - FX) +
          Row1[PixelOffset1 + Channel] * FX) * FY;
        Value := PByteRow(SourceRows[Y])^[X * 4 + Channel] *
          (1 - BlendWeight) + Value * BlendWeight;
        DestinationRow[X * 4 + Channel] :=
          EnsureRange(Round(Value), 0, 255);
      end;
    end;
  end;
{$IFDEF DEBUG}
  if (FLastTimingLog = 0) or
    (GetTickCount64 - FLastTimingLog >= 1000) then
  begin
    FLastTimingLog := GetTickCount64;
    Shake_PPP_DebugLog.DebugLog(Format(
      'Deformation frame applied: size=%dx%d offset=%.1f,%.1f elapsed=%dms.',
      [Source.Width, Source.Height, DisplacementX, DisplacementY,
       FLastTimingLog - StartedAt]));
  end;
{$ENDIF}
  Result := True;
end;

function TShakeDeformationMap.ApplyGripPreview(Source,
  Destination: Vcl.Graphics.TBitmap; const OriginalPositions,
  TargetPositions: TShakeGripPositions; const Enabled: TShakeGripEnabled;
  FullFrameMode: Boolean; out ErrorText: string): Boolean;
var
  BacksideGray: Double;
  BacksideWeight: Double;
  Channel: Integer;
  DestinationRow: PByteRow;
  DestinationRows: TBitmapRows;
  DistanceSquared: Double;
  DX: Double;
  DY: Double;
  FoldBand: Double;
  FoldShade: Double;
  FX: Double;
  FY: Double;
  GripDX: Double;
  GripDY: Double;
  GripForeshortening: Double;
  GripIndex: Integer;
  GripWeight: Double;
  Influence: Double;
  LiftLight: Double;
  MaskWeight: Double;
  OutsideDistance: Double;
  PathOffsetX: Double;
  PathOffsetY: Double;
  PixelOffset0: Integer;
  PixelOffset1: Integer;
  PreviewByteCount: NativeInt;
  PreviewDestinationRgba: TBytes;
  PreviewSourceRgba: TBytes;
  RadiusSquared: Double;
  Row0: PByteRow;
  Row1: PByteRow;
  SampleX: Double;
  SampleY: Double;
  SampledChannels: array[0..3] of Double;
  ShadowAlpha: Integer;
  ShadowRadius: Double;
  SourceRows: TBitmapRows;
  TotalWeight: Double;
  Value: Double;
  WeightedDX: Double;
  WeightedDY: Double;
  WeightedForeshortening: Double;
  WeightedForeshorteningX: Double;
  WeightedForeshorteningY: Double;
  X: Integer;
  XEnd: Integer;
  X0: Integer;
  X1: Integer;
  XStart: Integer;
  Y: Integer;
  YEnd: Integer;
  Y0: Integer;
  Y1: Integer;
  YStart: Integer;

  function DistanceSquaredToGripPath(Grip: Integer;
    PixelX, PixelY: Double; out OffsetX, OffsetY: Double): Double;
  var
    LengthSquared: Double;
    OriginX: Double;
    OriginY: Double;
    PathX: Double;
    PathY: Double;
    Projection: Double;
    TargetX: Double;
    TargetY: Double;
  begin
    OriginX := OriginalPositions[Grip].X * Max(1, FWidth - 1);
    OriginY := OriginalPositions[Grip].Y * Max(1, FHeight - 1);
    TargetX := TargetPositions[Grip].X * Max(1, FWidth - 1);
    TargetY := TargetPositions[Grip].Y * Max(1, FHeight - 1);
    PathX := TargetX - OriginX;
    PathY := TargetY - OriginY;
    LengthSquared := PathX * PathX + PathY * PathY;
    if LengthSquared > 1.0E-9 then
      Projection := EnsureRange(((PixelX - OriginX) * PathX +
        (PixelY - OriginY) * PathY) / LengthSquared, 0.0, 1.0)
    else
      Projection := 0;
    OffsetX := PixelX - (OriginX + PathX * Projection);
    OffsetY := PixelY - (OriginY + PathY * Projection);
    Result := Sqr(OffsetX) + Sqr(OffsetY);
  end;

begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) or
    (Source.Width <> FWidth) or (Source.Height <> FHeight) or
    (Length(FWeights) <> FWidth * FHeight) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;
  Source.PixelFormat := pf32bit;
  Destination.PixelFormat := pf32bit;
  Destination.SetSize(Source.Width, Source.Height);
  if not FullFrameMode then
  begin
    PreviewByteCount := NativeInt(Source.Width) * Source.Height * 4;
    SetLength(PreviewSourceRgba, PreviewByteCount);
    SetLength(PreviewDestinationRgba, PreviewByteCount);
    for Y := 0 to Source.Height - 1 do
      Move(Source.ScanLine[Source.Height - 1 - Y]^,
        PreviewSourceRgba[NativeInt(Y) * Source.Width * 4],
        NativeInt(Source.Width) * 4);
    Result := ApplyGripRgba(@PreviewSourceRgba[0],
      @PreviewDestinationRgba[0], OriginalPositions, TargetPositions,
      Enabled, tbsLegacy, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0,
      GRIP_PREVIEW_BACKSIDE_STRENGTH, 0.38,
      GRIP_PREVIEW_CAST_SHADOW_STRENGTH, 0.0, 2.0, 0.0, 0.0,
      False, False, ErrorText);
    if Result then
      for Y := 0 to Destination.Height - 1 do
        Move(PreviewDestinationRgba[NativeInt(Y) * Destination.Width * 4],
          Destination.ScanLine[Destination.Height - 1 - Y]^,
          NativeInt(Destination.Width) * 4);
    Exit;
  end;
  SetLength(SourceRows, Source.Height);
  SetLength(DestinationRows, Destination.Height);
  for Y := 0 to Source.Height - 1 do
  begin
    SourceRows[Y] := Source.ScanLine[Source.Height - 1 - Y];
    DestinationRows[Y] := Destination.ScanLine[Destination.Height - 1 - Y];
    Move(SourceRows[Y]^, DestinationRows[Y]^, NativeInt(Source.Width) * 4);
  end;
  RadiusSquared := Sqr(Max(FWidth, FHeight) * 0.38);
  ShadowRadius := Max(1.0, Max(FWidth, FHeight) * GRIP_CAST_SHADOW_RADIUS);
  if FullFrameMode then
  begin
    XStart := 0;
    YStart := 0;
    XEnd := FWidth - 1;
    YEnd := FHeight - 1;
  end
  else
  begin
    XStart := FActiveLeft;
    YStart := FActiveTop;
    XEnd := FActiveRight;
    YEnd := FActiveBottom;
  end;
  for Y := YStart to YEnd do
  begin
    DestinationRow := PByteRow(DestinationRows[Y]);
    for X := XStart to XEnd do
    begin
      if FullFrameMode then
        MaskWeight := 1
      else
        MaskWeight := Sqr(FWeights[(FHeight - 1 - Y) * FWidth + X]);
      if MaskWeight <= 0 then
        Continue;
      TotalWeight := 0;
      WeightedDX := 0;
      WeightedDY := 0;
      WeightedForeshortening := 0;
      WeightedForeshorteningX := 0;
      WeightedForeshorteningY := 0;
      Influence := 0;
      for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
      begin
        if not Enabled[GripIndex] then
          Continue;
        DistanceSquared := DistanceSquaredToGripPath(GripIndex, X, Y,
          PathOffsetX, PathOffsetY);
        GripWeight := Exp(-2 * DistanceSquared / RadiusSquared);
        GripDX := (TargetPositions[GripIndex].X -
          OriginalPositions[GripIndex].X) * Max(1, FWidth - 1);
        { SourceRows and DestinationRows are indexed top-to-bottom, matching
          normalized editor coordinates and the AviUtl2 RGBA path. }
        GripDY := (TargetPositions[GripIndex].Y -
          OriginalPositions[GripIndex].Y) * Max(1, FHeight - 1);
        GripForeshortening := Min(GRIP_MAX_FORESHORTENING,
          Sqrt(GripDX * GripDX + GripDY * GripDY) /
          Max(FWidth, FHeight) * GRIP_FORESHORTENING_GAIN);
        TotalWeight := TotalWeight + GripWeight;
        WeightedDX := WeightedDX + GripDX * GripWeight;
        WeightedDY := WeightedDY + GripDY * GripWeight;
        WeightedForeshortening := WeightedForeshortening +
          GripForeshortening * GripWeight;
        WeightedForeshorteningX := WeightedForeshorteningX +
          PathOffsetX * GripForeshortening * GripWeight;
        WeightedForeshorteningY := WeightedForeshorteningY +
          PathOffsetY * GripForeshortening * GripWeight;
        Influence := Max(Influence, GripWeight);
      end;
      if TotalWeight <= 1.0E-9 then
        Continue;
      DX := WeightedDX / TotalWeight * Influence * MaskWeight;
      DY := WeightedDY / TotalWeight * Influence * MaskWeight;
      FoldBand := 4 * Influence * (1 - Influence);
      FoldShade := 1 - WeightedForeshortening / TotalWeight *
        GRIP_FOLD_SHADOW_GAIN * FoldBand * MaskWeight;
      LiftLight := 1 + WeightedForeshortening / TotalWeight *
        GRIP_LIFT_LIGHT_GAIN * Sqr(Influence) * MaskWeight;
      { Pull source samples away from each grip path.  The destination image
        consequently narrows toward that path, giving the lifted portion a
        simple fold/foreshortening cue without changing the grip endpoint. }
      SampleX := X - DX + WeightedForeshorteningX / TotalWeight *
        Influence * MaskWeight;
      SampleY := Y - DY + WeightedForeshorteningY / TotalWeight *
        Influence * MaskWeight;
      if FullFrameMode and ((SampleX < 0) or (SampleX > FWidth - 1) or
        (SampleY < 0) or (SampleY > FHeight - 1)) then
      begin
        OutsideDistance := Max(Max(-SampleX, SampleX - (FWidth - 1)),
          Max(-SampleY, SampleY - (FHeight - 1)));
        ShadowAlpha := EnsureRange(Round(255 *
          GRIP_PREVIEW_CAST_SHADOW_STRENGTH *
          Exp(-OutsideDistance / ShadowRadius)), 0, 255);
        for Channel := 0 to 2 do
          DestinationRow[X * 4 + Channel] := 0;
        DestinationRow[X * 4 + 3] := ShadowAlpha;
        Continue;
      end;
      SampleX := EnsureRange(SampleX, 0.0, FWidth - 1.0);
      SampleY := EnsureRange(SampleY, 0.0, FHeight - 1.0);
      X0 := Trunc(SampleX);
      Y0 := Trunc(SampleY);
      X1 := Min(X0 + 1, FWidth - 1);
      Y1 := Min(Y0 + 1, FHeight - 1);
      FX := SampleX - X0;
      FY := SampleY - Y0;
      Row0 := PByteRow(SourceRows[Y0]);
      Row1 := PByteRow(SourceRows[Y1]);
      PixelOffset0 := X0 * 4;
      PixelOffset1 := X1 * 4;
      for Channel := 0 to 3 do
      begin
        Value := (Row0[PixelOffset0 + Channel] * (1 - FX) +
          Row0[PixelOffset1 + Channel] * FX) * (1 - FY) +
          (Row1[PixelOffset0 + Channel] * (1 - FX) +
          Row1[PixelOffset1 + Channel] * FX) * FY;
        SampledChannels[Channel] := Value;
      end;
      BacksideGray := (SampledChannels[0] + SampledChannels[1] +
        SampledChannels[2]) / 3;
      BacksideWeight := EnsureRange(WeightedForeshortening / TotalWeight /
        GRIP_MAX_FORESHORTENING * Sqr(Influence) * MaskWeight *
        GRIP_PREVIEW_BACKSIDE_STRENGTH, 0.0, 1.0);
      for Channel := 0 to 3 do
      begin
        Value := SampledChannels[Channel];
        if Channel < 3 then
        begin
          Value := Value * (1 - GRIP_BACKSIDE_DESATURATION *
            BacksideWeight) + BacksideGray * GRIP_BACKSIDE_DESATURATION *
            BacksideWeight;
          Value := Value * FoldShade * LiftLight *
            (1 - GRIP_BACKSIDE_DARKENING * BacksideWeight);
        end;
        DestinationRow[X * 4 + Channel] :=
          EnsureRange(Round(Value), 0, 255);
      end;
    end;
  end;
  Result := True;
end;

function TShakeDeformationMap.ApplyRgba(Source, Destination: Pointer;
  DisplacementX, DisplacementY: Double;
  out ErrorText: string): Boolean;
type
  PRgbaBytes = ^TRgbaBytes;
  TRgbaBytes = array[0..268435455] of Byte;
var
  BlendWeight: Double;
  Channel: Integer;
  FX: Double;
  FY: Double;
  PixelOffset00: NativeInt;
  PixelOffset01: NativeInt;
  PixelOffset10: NativeInt;
  PixelOffset11: NativeInt;
  SourceBytes: PRgbaBytes;
  DestinationBytes: PRgbaBytes;
  ByteCount: NativeInt;
  SourceX: Double;
  SourceY: Double;
  Value: Double;
  Weight: Double;
  WeightY: Integer;
  X: Integer;
  X0: Integer;
  X1: Integer;
  Y: Integer;
  Y0: Integer;
  Y1: Integer;
begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) or (FWidth <= 0) or
    (FHeight <= 0) or (Length(FWeights) <> FWidth * FHeight) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;
  SourceBytes := Source;
  DestinationBytes := Destination;
  ByteCount := NativeInt(FWidth) * FHeight * 4;
  Move(SourceBytes^, DestinationBytes^, ByteCount);
  for Y := FActiveTop to FActiveBottom do
  begin
    // AviUtl2 RGBA rows are top-to-bottom, while FWeights follows the
    // bottom-to-top TBitmap scanline order used by the settings preview.
    WeightY := FHeight - 1 - Y;
    for X := FActiveLeft to FActiveRight do
    begin
      Weight := FWeights[WeightY * FWidth + X];
      BlendWeight := Weight * Weight;
      SourceX := EnsureRange(X - DisplacementX * Weight,
        0.0, FWidth - 1.0);
      SourceY := EnsureRange(Y - DisplacementY * Weight,
        0.0, FHeight - 1.0);
      X0 := Trunc(SourceX);
      Y0 := Trunc(SourceY);
      X1 := Min(X0 + 1, FWidth - 1);
      Y1 := Min(Y0 + 1, FHeight - 1);
      FX := SourceX - X0;
      FY := SourceY - Y0;
      PixelOffset00 := (NativeInt(Y0) * FWidth + X0) * 4;
      PixelOffset01 := (NativeInt(Y0) * FWidth + X1) * 4;
      PixelOffset10 := (NativeInt(Y1) * FWidth + X0) * 4;
      PixelOffset11 := (NativeInt(Y1) * FWidth + X1) * 4;
      for Channel := 0 to 3 do
      begin
        Value := (SourceBytes^[PixelOffset00 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset01 + Channel] * FX) * (1 - FY) +
          (SourceBytes^[PixelOffset10 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset11 + Channel] * FX) * FY;
        Value := SourceBytes^[(NativeInt(Y) * FWidth + X) * 4 + Channel] *
          (1 - BlendWeight) + Value * BlendWeight;
        DestinationBytes^[(NativeInt(Y) * FWidth + X) * 4 + Channel] :=
          EnsureRange(Round(Value), 0, 255);
      end;
    end;
  end;
  Result := True;
end;

function TShakeDeformationMap.ApplyGripRgba(Source, Destination: Pointer;
  const OriginalPositions, TargetPositions: TShakeGripPositions;
  const Enabled: TShakeGripEnabled; BillowStyle: TTurnOverBillowStyle;
  BillowDisplacementX, BillowDisplacementY, BillowStrength,
  GravityStrength, ShrinkRate, FoldStrength, LightingStrength,
  BacksideStrength,
  InfluenceRadius, CastShadowStrength: Double;
  RippleStrength, RippleCount, RipplePhase,
  RippleDirectionDegrees: Double; FullFrameMode,
  TightPartialCoverage: Boolean;
  out ErrorText: string): Boolean;
type
  PRgbaBytes = ^TRgbaBytes;
  TRgbaBytes = array[0..268435455] of Byte;
var
  AverageGripDX: Double;
  AverageGripDY: Double;
  DestinationBytes: PRgbaBytes;
  DistanceSquared: Double;
  EnabledGripCount: Integer;
  GripDX: array[0..SHAKE_GRIP_POINT_COUNT - 1] of Double;
  GripDY: array[0..SHAKE_GRIP_POINT_COUNT - 1] of Double;
  GripForeshortening: array[0..SHAKE_GRIP_POINT_COUNT - 1] of Double;
  GripIndex: Integer;
  GripOriginX: array[0..SHAKE_GRIP_POINT_COUNT - 1] of Double;
  GripOriginY: array[0..SHAKE_GRIP_POINT_COUNT - 1] of Double;
  GripPathInverseLengthSquared:
    array[0..SHAKE_GRIP_POINT_COUNT - 1] of Double;
  GripPathX: array[0..SHAKE_GRIP_POINT_COUNT - 1] of Double;
  GripPathY: array[0..SHAKE_GRIP_POINT_COUNT - 1] of Double;
  FlutterAmplitude: Double;
  FlutterChaos: Double;
  FlutterDepth: Double;
  FlutterDepthCosineLut: TDoubleArray;
  FlutterDepthSineLut: TDoubleArray;
  FlutterForwardNormalLut: TDoubleArray;
  FlutterInverseSegment: Integer;
  FlutterInverseSource: Double;
  FlutterLutIndex: Integer;
  FlutterMapOffset: NativeInt;
  FlutterNormalDisplacementLut: TDoubleArray;
  FlutterPhase: Double;
  FlutterTangentCosineLut: TDoubleArray;
  FlutterTangentIndex: Integer;
  FlutterTangentLength: Integer;
  FlutterTangentSineLut: TDoubleArray;
  FlutterTangentOffsetLut: TDoubleArray;
  FlutterTangentPositionLut: TDoubleArray;
  FlutterRawDisplacementLut: TDoubleArray;
  FlutterRotationStep: Double;
  FlutterSegmentLength: Double;
  FlutterSourceIndex: Integer;
  FlutterSourceIndex1: Integer;
  FlutterTangentCenterOffset: Double;
  FlutterNoiseAnchor: Integer;
  FlutterNoiseCoordinate: Double;
  FlutterNoiseFraction: Double;
  FlutterNoiseNext: Double;
  FlutterNoiseSpacing: Integer;
  FlutterTangentNoise: Double;
  PartialAxisLengthSquared: Double;
  PartialAxisX: Double;
  PartialAxisY: Double;
  PartialBX: Double;
  PartialBY: Double;
  PartialDeterminant: Double;
  PartialFirstGrip: Integer;
  PartialInverse11: Double;
  PartialInverse12: Double;
  PartialInverse21: Double;
  PartialInverse22: Double;
  PartialM11: Double;
  PartialM12: Double;
  PartialM21: Double;
  PartialM22: Double;
  PartialOriginProjection: Double;
  PartialSecondGrip: Integer;
  ImageHeightScale: Double;
  ImageMaximumDimension: Double;
  ImageWidthScale: Double;
  ImageCenterX: Double;
  ImageCenterY: Double;
  InverseRadiusSquared: Double;
  MaximumGripMotion: Double;
  MotionMargin: Integer;
  FixedFieldEnabled: Boolean;
  RippleAngularScale: Double;
  RippleDirectionCosine: Double;
  RippleDirectionRadians: Double;
  RippleDirectionSine: Double;
  RippleStepCosine: Double;
  RippleStepSine: Double;
  ShadowRadius: Double;
  SourceBytes: PRgbaBytes;
  XEnd: Integer;
  XStart: Integer;
  YEnd: Integer;
  YStart: Integer;

begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) or (FWidth <= 0) or
    (FHeight <= 0) or (Length(FWeights) <> FWidth * FHeight) or
    (Length(FCoverage) <> FWidth * FHeight) or
    (Length(FTightCoverage) <> FWidth * FHeight) or
    (Length(FFixedTopBlend) <> FWidth * FHeight) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;
  SourceBytes := Source;
  DestinationBytes := Destination;
  FoldStrength := EnsureRange(FoldStrength, 0.0, 2.0);
  LightingStrength := EnsureRange(LightingStrength, 0.0, 2.0);
  BacksideStrength := EnsureRange(BacksideStrength, 0.0, 1.0);
  InfluenceRadius := EnsureRange(InfluenceRadius, 0.05, 1.0);
  CastShadowStrength := EnsureRange(CastShadowStrength, 0.0, 1.0);
  ImageWidthScale := Max(1, FWidth - 1);
  ImageHeightScale := Max(1, FHeight - 1);
  ImageCenterX := (FWidth - 1) * 0.5;
  ImageCenterY := (FHeight - 1) * 0.5;
  if FullFrameMode then
    ShrinkRate := EnsureRange(ShrinkRate, 0.1, 1.0)
  else
    ShrinkRate := 1;
  ImageMaximumDimension := Max(FWidth, FHeight);
  RippleStrength := EnsureRange(RippleStrength, 0.0,
    ImageMaximumDimension * 2.0);
  RippleCount := EnsureRange(RippleCount, 1.0, 10.0);
  RippleDirectionRadians := DegToRad(RippleDirectionDegrees);
  RippleDirectionCosine := Cos(RippleDirectionRadians);
  RippleDirectionSine := Sin(RippleDirectionRadians);
  RippleAngularScale := 2 * Pi * RippleCount / ImageMaximumDimension;
  RippleStepSine := Sin(RippleDirectionCosine * RippleAngularScale);
  RippleStepCosine := Cos(RippleDirectionCosine * RippleAngularScale);
  InverseRadiusSquared := 1 /
    Sqr(ImageMaximumDimension * InfluenceRadius);
  ShadowRadius := Max(1.0,
    ImageMaximumDimension * GRIP_CAST_SHADOW_RADIUS);
  AverageGripDX := 0;
  AverageGripDY := 0;
  EnabledGripCount := 0;
  MaximumGripMotion := Max(Abs(BillowDisplacementX),
    Abs(BillowDisplacementY));
  BillowStrength := Max(0, BillowStrength);
  GravityStrength := Max(0, GravityStrength);
  MaximumGripMotion := Max(MaximumGripMotion, GravityStrength);
  FixedFieldEnabled :=
    (BillowStyle in [tbsBend, tbsSway, tbsFlutter]) or
    (GravityStrength > 0);
  if BillowStyle = tbsFlutter then
  begin
    FlutterAmplitude := BillowStrength * 0.35 + RippleStrength * 0.20;
    SetLength(FlutterDepthSineLut, FLUTTER_DEPTH_LUT_SIZE + 1);
    SetLength(FlutterDepthCosineLut, FLUTTER_DEPTH_LUT_SIZE + 1);
    for FlutterLutIndex := 0 to FLUTTER_DEPTH_LUT_SIZE do
    begin
      FlutterDepth := FlutterLutIndex / FLUTTER_DEPTH_LUT_SIZE;
      FlutterPhase := RipplePhase - FlutterDepth * 2 * Pi * RippleCount;
      FlutterDepthSineLut[FlutterLutIndex] := Sin(FlutterPhase);
      FlutterDepthCosineLut[FlutterLutIndex] := Cos(FlutterPhase);
    end;
    if FFixedEdge in [tfeLeft, tfeRight] then
      FlutterTangentLength := FHeight
    else
      FlutterTangentLength := FWidth;
    SetLength(FlutterTangentSineLut, FlutterTangentLength);
    SetLength(FlutterTangentCosineLut, FlutterTangentLength);
    { Larger motion needs a longer correlation distance to prevent adjacent
      one-pixel strips from tearing the free edge into a sawtooth. }
    FlutterNoiseSpacing := Min(Max(1, FlutterTangentLength - 1),
      Max(24, Round(Sqrt(Max(1.0, FlutterAmplitude)) * 5)));
    for FlutterTangentIndex := 0 to FlutterTangentLength - 1 do
    begin
      { Stable random anchors are smoothly interpolated across one-pixel
        strips.  SmoothStep gives zero slope at each anchor, preserving an
        irregular shape without discontinuities at the free edge. }
      FlutterNoiseCoordinate := FlutterTangentIndex / FlutterNoiseSpacing;
      FlutterNoiseAnchor := Floor(FlutterNoiseCoordinate);
      FlutterNoiseFraction := Frac(FlutterNoiseCoordinate);
      FlutterNoiseFraction := Sqr(FlutterNoiseFraction) *
        (3 - 2 * FlutterNoiseFraction);
      FlutterTangentNoise := Frac((FlutterNoiseAnchor + 1) *
        0.7548776662466927 + Sqr((FlutterNoiseAnchor + 1) *
        0.137873));
      FlutterNoiseNext := Frac((FlutterNoiseAnchor + 2) *
        0.7548776662466927 + Sqr((FlutterNoiseAnchor + 2) *
        0.137873));
      FlutterTangentNoise := FlutterTangentNoise *
        (1 - FlutterNoiseFraction) + FlutterNoiseNext * FlutterNoiseFraction;
      FlutterPhase := FlutterTangentIndex / Max(1,
        FlutterTangentLength - 1) * Pi * RippleCount * 0.35 +
        (FlutterTangentNoise - 0.5) * 0.9;
      FlutterTangentSineLut[FlutterTangentIndex] := Sin(FlutterPhase);
      FlutterTangentCosineLut[FlutterTangentIndex] := Cos(FlutterPhase);
    end;
    SetLength(FlutterNormalDisplacementLut,
      (FLUTTER_DEPTH_LUT_SIZE + 1) * FlutterTangentLength);
    SetLength(FlutterTangentOffsetLut,
      (FLUTTER_DEPTH_LUT_SIZE + 1) * FlutterTangentLength);
    SetLength(FlutterRawDisplacementLut, FlutterTangentLength);
    SetLength(FlutterForwardNormalLut, FlutterTangentLength);
    SetLength(FlutterTangentPositionLut, FlutterTangentLength);
    for FlutterLutIndex := 0 to FLUTTER_DEPTH_LUT_SIZE do
    begin
      FlutterDepth := FlutterLutIndex / FLUTTER_DEPTH_LUT_SIZE;
      FlutterMapOffset := NativeInt(FlutterLutIndex) * FlutterTangentLength;
      for FlutterTangentIndex := 0 to FlutterTangentLength - 1 do
      begin
        FlutterChaos :=
          FlutterDepthSineLut[FlutterLutIndex] *
          FlutterTangentCosineLut[FlutterTangentIndex] +
          FlutterDepthCosineLut[FlutterLutIndex] *
          FlutterTangentSineLut[FlutterTangentIndex];
        FlutterRawDisplacementLut[FlutterTangentIndex] :=
          FlutterAmplitude *
          (FlutterDepthSineLut[FlutterLutIndex] * FlutterDepth * 0.45 +
          FlutterChaos * Sqr(FlutterDepth) * 0.55);
      end;
      FlutterForwardNormalLut[0] := FlutterRawDisplacementLut[0];
      FlutterTangentPositionLut[0] := 0;
      for FlutterTangentIndex := 1 to FlutterTangentLength - 1 do
      begin
        { Rotate the original one-pixel tangent vector instead of translating
          neighboring strips independently.  Its normal component is capped;
          the tangent component completes a vector whose length is exactly 1. }
        FlutterRotationStep := EnsureRange(
          FlutterRawDisplacementLut[FlutterTangentIndex] -
          FlutterRawDisplacementLut[FlutterTangentIndex - 1],
          -FLUTTER_MAX_NORMAL_STEP, FLUTTER_MAX_NORMAL_STEP);
        FlutterForwardNormalLut[FlutterTangentIndex] :=
          FlutterForwardNormalLut[FlutterTangentIndex - 1] +
          FlutterRotationStep;
        FlutterTangentPositionLut[FlutterTangentIndex] :=
          FlutterTangentPositionLut[FlutterTangentIndex - 1] +
          Sqrt(Max(0.0, 1 - Sqr(FlutterRotationStep)));
      end;
      FlutterTangentCenterOffset :=
        (FlutterTangentLength - 1 -
        FlutterTangentPositionLut[FlutterTangentLength - 1]) * 0.5;
      for FlutterTangentIndex := 0 to FlutterTangentLength - 1 do
        FlutterTangentPositionLut[FlutterTangentIndex] :=
          FlutterTangentPositionLut[FlutterTangentIndex] +
          FlutterTangentCenterOffset;
      if FlutterTangentLength = 1 then
      begin
        FlutterNormalDisplacementLut[FlutterMapOffset] :=
          FlutterForwardNormalLut[0];
        FlutterTangentOffsetLut[FlutterMapOffset] := 0;
      end
      else
      begin
        FlutterInverseSegment := 0;
        for FlutterTangentIndex := 0 to FlutterTangentLength - 1 do
        begin
          if FlutterTangentIndex <= FlutterTangentPositionLut[0] then
          begin
            FlutterSegmentLength := Max(1.0E-9,
              FlutterTangentPositionLut[1] -
              FlutterTangentPositionLut[0]);
            FlutterInverseSource := (FlutterTangentIndex -
              FlutterTangentPositionLut[0]) / FlutterSegmentLength;
          end
          else if FlutterTangentIndex >=
            FlutterTangentPositionLut[FlutterTangentLength - 1] then
          begin
            FlutterSegmentLength := Max(1.0E-9,
              FlutterTangentPositionLut[FlutterTangentLength - 1] -
              FlutterTangentPositionLut[FlutterTangentLength - 2]);
            FlutterInverseSource := FlutterTangentLength - 1 +
              (FlutterTangentIndex -
              FlutterTangentPositionLut[FlutterTangentLength - 1]) /
              FlutterSegmentLength;
          end
          else
          begin
            while (FlutterInverseSegment < FlutterTangentLength - 2) and
              (FlutterTangentPositionLut[FlutterInverseSegment + 1] <
              FlutterTangentIndex) do
              Inc(FlutterInverseSegment);
            FlutterSegmentLength := Max(1.0E-9,
              FlutterTangentPositionLut[FlutterInverseSegment + 1] -
              FlutterTangentPositionLut[FlutterInverseSegment]);
            FlutterInverseSource := FlutterInverseSegment +
              (FlutterTangentIndex -
              FlutterTangentPositionLut[FlutterInverseSegment]) /
              FlutterSegmentLength;
          end;
          FlutterTangentOffsetLut[FlutterMapOffset +
            FlutterTangentIndex] :=
            FlutterTangentIndex - FlutterInverseSource;
          FlutterSourceIndex := EnsureRange(Trunc(FlutterInverseSource),
            0, FlutterTangentLength - 1);
          FlutterSourceIndex1 := Min(FlutterSourceIndex + 1,
            FlutterTangentLength - 1);
          FlutterNoiseFraction := EnsureRange(FlutterInverseSource -
            FlutterSourceIndex, 0.0, 1.0);
          FlutterNormalDisplacementLut[FlutterMapOffset +
            FlutterTangentIndex] :=
            FlutterForwardNormalLut[FlutterSourceIndex] *
            (1 - FlutterNoiseFraction) +
            FlutterForwardNormalLut[FlutterSourceIndex1] *
            FlutterNoiseFraction;
        end;
      end;
    end;
    MaximumGripMotion := Max(MaximumGripMotion, FlutterAmplitude);
  end;
  for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
    if Enabled[GripIndex] then
    begin
      GripOriginX[GripIndex] := ImageCenterX +
        (OriginalPositions[GripIndex].X * ImageWidthScale -
        ImageCenterX) * ShrinkRate;
      GripOriginY[GripIndex] := ImageCenterY +
        (OriginalPositions[GripIndex].Y * ImageHeightScale -
        ImageCenterY) * ShrinkRate;
      GripPathX[GripIndex] := (TargetPositions[GripIndex].X -
        OriginalPositions[GripIndex].X) * ImageWidthScale;
      GripPathY[GripIndex] := (TargetPositions[GripIndex].Y -
        OriginalPositions[GripIndex].Y) * ImageHeightScale;
      GripDX[GripIndex] := GripPathX[GripIndex];
      GripDY[GripIndex] := GripPathY[GripIndex];
      AverageGripDX := AverageGripDX + GripDX[GripIndex];
      AverageGripDY := AverageGripDY + GripDY[GripIndex];
      Inc(EnabledGripCount);
      DistanceSquared := Sqr(GripPathX[GripIndex]) +
        Sqr(GripPathY[GripIndex]);
      if DistanceSquared > 1.0E-9 then
        GripPathInverseLengthSquared[GripIndex] := 1 / DistanceSquared
      else
        GripPathInverseLengthSquared[GripIndex] := 0;
      GripForeshortening[GripIndex] := Min(GRIP_MAX_FORESHORTENING,
        Sqrt(DistanceSquared) / ImageMaximumDimension *
        GRIP_FORESHORTENING_GAIN) * FoldStrength;
      MaximumGripMotion := Max(MaximumGripMotion,
        Max(Abs(GripDX[GripIndex]), Abs(GripDY[GripIndex])));
    end;
  if EnabledGripCount > 0 then
  begin
    AverageGripDX := AverageGripDX / EnabledGripCount;
    AverageGripDY := AverageGripDY / EnabledGripCount;
  end;
  { The partial-selection path is one continuous movable layer.  Build the
    exact inverse of the affine field that maps grip 1 to its target and grip
    2 to its target.  This avoids the gaps and duplicated source strips caused
    by evaluating a nonlinear displacement only at the destination pixel. }
  PartialInverse11 := 1;
  PartialInverse12 := 0;
  PartialInverse21 := 0;
  PartialInverse22 := 1;
  PartialBX := AverageGripDX;
  PartialBY := AverageGripDY;
  PartialFirstGrip := -1;
  PartialSecondGrip := -1;
  for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
    if Enabled[GripIndex] then
      if PartialFirstGrip < 0 then
        PartialFirstGrip := GripIndex
      else if PartialSecondGrip < 0 then
        PartialSecondGrip := GripIndex;
  if PartialFirstGrip >= 0 then
  begin
    PartialBX := GripDX[PartialFirstGrip];
    PartialBY := GripDY[PartialFirstGrip];
  end;
  if PartialSecondGrip >= 0 then
  begin
    PartialAxisX := GripOriginX[PartialSecondGrip] -
      GripOriginX[PartialFirstGrip];
    PartialAxisY := GripOriginY[PartialSecondGrip] -
      GripOriginY[PartialFirstGrip];
    PartialAxisLengthSquared := Sqr(PartialAxisX) + Sqr(PartialAxisY);
    if PartialAxisLengthSquared > 1.0E-9 then
    begin
      PartialM11 := 1 + (GripDX[PartialSecondGrip] -
        GripDX[PartialFirstGrip]) * PartialAxisX /
        PartialAxisLengthSquared;
      PartialM12 := (GripDX[PartialSecondGrip] -
        GripDX[PartialFirstGrip]) * PartialAxisY /
        PartialAxisLengthSquared;
      PartialM21 := (GripDY[PartialSecondGrip] -
        GripDY[PartialFirstGrip]) * PartialAxisX /
        PartialAxisLengthSquared;
      PartialM22 := 1 + (GripDY[PartialSecondGrip] -
        GripDY[PartialFirstGrip]) * PartialAxisY /
        PartialAxisLengthSquared;
      PartialOriginProjection :=
        (GripOriginX[PartialFirstGrip] * PartialAxisX +
        GripOriginY[PartialFirstGrip] * PartialAxisY) /
        PartialAxisLengthSquared;
      PartialBX := GripDX[PartialFirstGrip] -
        (GripDX[PartialSecondGrip] - GripDX[PartialFirstGrip]) *
        PartialOriginProjection;
      PartialBY := GripDY[PartialFirstGrip] -
        (GripDY[PartialSecondGrip] - GripDY[PartialFirstGrip]) *
        PartialOriginProjection;
      PartialDeterminant := PartialM11 * PartialM22 -
        PartialM12 * PartialM21;
      if Abs(PartialDeterminant) > 1.0E-9 then
      begin
        PartialInverse11 := PartialM22 / PartialDeterminant;
        PartialInverse12 := -PartialM12 / PartialDeterminant;
        PartialInverse21 := -PartialM21 / PartialDeterminant;
        PartialInverse22 := PartialM11 / PartialDeterminant;
      end
      else
      begin
        PartialInverse11 := 1;
        PartialInverse12 := 0;
        PartialInverse21 := 0;
        PartialInverse22 := 1;
        PartialBX := AverageGripDX;
        PartialBY := AverageGripDY;
      end;
    end;
  end;
  if not FullFrameMode then
  begin
    Move(SourceBytes^, DestinationBytes^, NativeInt(FWidth) * FHeight * 4);
    { Remove the original selected layer.  Pixels outside the saved contour
      remain byte-for-byte unchanged; the moved selection is composited over
      them below. }
    TParallel.&For(FActiveTop, FActiveBottom,
      procedure(Y: Integer)
      var
        Coverage: Double;
        DestinationOffset: NativeInt;
        LocalX: Integer;
      begin
        for LocalX := FActiveLeft to FActiveRight do
        begin
          if TightPartialCoverage then
            Coverage := FTightCoverage[
              (FHeight - 1 - Y) * FWidth + LocalX]
          else
            Coverage := FCoverage[
              (FHeight - 1 - Y) * FWidth + LocalX];
          if Coverage <= 0 then
            Continue;
          DestinationOffset := (NativeInt(Y) * FWidth + LocalX) * 4;
          DestinationBytes^[DestinationOffset + 3] := EnsureRange(Round(
            DestinationBytes^[DestinationOffset + 3] * (1 - Coverage)),
            0, 255);
        end;
      end);
  end;
  if FullFrameMode then
  begin
    XStart := 0;
    YStart := 0;
    XEnd := FWidth - 1;
    YEnd := FHeight - 1;
  end
  else
  begin
    MotionMargin := Ceil(MaximumGripMotion + Abs(RippleStrength));
    XStart := Max(0, FActiveLeft - MotionMargin);
    YStart := Max(0, FActiveTop - MotionMargin);
    XEnd := Min(FWidth - 1, FActiveRight + MotionMargin);
    YEnd := Min(FHeight - 1, FActiveBottom + MotionMargin);
  end;
  TParallel.&For(YStart, YEnd,
    procedure(Y: Integer)
    var
      BacksideGray: Double;
      BacksideWeight: Double;
      BoundarySample: Boolean;
      Channel: Integer;
      DestinationOffset: NativeInt;
      DistanceSquared: Double;
      DX: Double;
      DY: Double;
      FoldBand: Double;
      FoldShade: Double;
      FX: Double;
      FY: Double;
      GripIndex: Integer;
      GripWeight: Double;
      Influence: Double;
      LiftLight: Double;
      MapFX: Double;
      MapFY: Double;
      MapX0: Integer;
      MapX1: Integer;
      MapY0: Integer;
      MapY1: Integer;
      MaskWeight: Double;
      NextRippleCosine: Double;
      NextRippleSine: Double;
      OutsideDistance: Double;
      PathOffsetX: Double;
      PathOffsetY: Double;
      PartialAnchorBlend: Double;
      BillowBlend: Double;
      FlutterDepthFraction: Double;
      FlutterDepthPosition: Double;
      FlutterDisplacement: Double;
      FlutterIndex: Integer;
      FlutterIndex1: Integer;
      FlutterMapOffset0: NativeInt;
      FlutterMapOffset1: NativeInt;
      FlutterTangentOffset: Double;
      FlutterTangentPixel: Integer;
      PixelOffset00: NativeInt;
      PixelOffset01: NativeInt;
      PixelOffset10: NativeInt;
      PixelOffset11: NativeInt;
      Projection: Double;
      Ripple: Double;
      RippleCosine: Double;
      RippleSine: Double;
      SampleX: Double;
      SampleY: Double;
      SampledChannels: array[0..3] of Double;
      ShadowAlpha: Integer;
      TotalWeight: Double;
      Value: Double;
      WeightedDX: Double;
      WeightedDY: Double;
      WeightedForeshortening: Double;
      WeightedForeshorteningX: Double;
      WeightedForeshorteningY: Double;
      Weight00: Double;
      Weight01: Double;
      Weight10: Double;
      Weight11: Double;
      X: Integer;
      X0: Integer;
      X1: Integer;
      Y0: Integer;
      Y1: Integer;
      function SourceChannelAt(SourceX, SourceY, SourceChannel: Integer): Double;
      begin
        if (SourceX < 0) or (SourceX >= FWidth) or
          (SourceY < 0) or (SourceY >= FHeight) then
          Exit(0);
        Result := SourceBytes^[(NativeInt(SourceY) * FWidth + SourceX) * 4 +
          SourceChannel];
      end;
    begin
    if (RippleStrength > 0) and (BillowStyle <> tbsFlutter) then
    begin
      RippleSine := Sin((XStart * RippleDirectionCosine +
        Y * RippleDirectionSine) * RippleAngularScale - RipplePhase);
      RippleCosine := Cos((XStart * RippleDirectionCosine +
        Y * RippleDirectionSine) * RippleAngularScale - RipplePhase);
    end;
    for X := XStart to XEnd do
    begin
      if FixedFieldEnabled then
        PartialAnchorBlend := FFixedTopBlend[
          (FHeight - 1 - Y) * FWidth + X]
      else if FullFrameMode then
        PartialAnchorBlend := 1
      else
        PartialAnchorBlend := FFixedTopBlend[
          (FHeight - 1 - Y) * FWidth + X];
      if (RippleStrength > 0) and (BillowStyle <> tbsFlutter) then
      begin
        Ripple := RippleSine;
        NextRippleSine := RippleSine * RippleStepCosine +
          RippleCosine * RippleStepSine;
        NextRippleCosine := RippleCosine * RippleStepCosine -
          RippleSine * RippleStepSine;
        RippleSine := NextRippleSine;
        RippleCosine := NextRippleCosine;
      end;
      if FullFrameMode then
        MaskWeight := 1
      else
        MaskWeight := 1;
      TotalWeight := 0;
      WeightedDX := 0;
      WeightedDY := 0;
      WeightedForeshortening := 0;
      WeightedForeshorteningX := 0;
      WeightedForeshorteningY := 0;
      Influence := 0;
      for GripIndex := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
      begin
        if not Enabled[GripIndex] then
          Continue;
        if GripPathInverseLengthSquared[GripIndex] > 0 then
          Projection := EnsureRange(((X - GripOriginX[GripIndex]) *
            GripPathX[GripIndex] + (Y - GripOriginY[GripIndex]) *
            GripPathY[GripIndex]) *
            GripPathInverseLengthSquared[GripIndex], 0.0, 1.0)
        else
          Projection := 0;
        PathOffsetX := X - (GripOriginX[GripIndex] +
          GripPathX[GripIndex] * Projection);
        PathOffsetY := Y - (GripOriginY[GripIndex] +
          GripPathY[GripIndex] * Projection);
        DistanceSquared := Sqr(PathOffsetX) + Sqr(PathOffsetY);
        GripWeight := LookupGripWeight(DistanceSquared,
          InverseRadiusSquared);
        if GripWeight <= 0 then
          Continue;
        TotalWeight := TotalWeight + GripWeight;
        WeightedDX := WeightedDX + GripDX[GripIndex] * GripWeight;
        WeightedDY := WeightedDY + GripDY[GripIndex] * GripWeight;
        WeightedForeshortening := WeightedForeshortening +
          GripForeshortening[GripIndex] * GripWeight;
        WeightedForeshorteningX := WeightedForeshorteningX +
          PathOffsetX * GripForeshortening[GripIndex] * GripWeight;
        WeightedForeshorteningY := WeightedForeshorteningY +
          PathOffsetY * GripForeshortening[GripIndex] * GripWeight;
        Influence := Max(Influence, GripWeight);
      end;
      if TotalWeight <= 1.0E-9 then
      begin
        if RippleStrength <= 0 then
        begin
          if FullFrameMode and SameValue(ShrinkRate, 1, 1.0E-9) and
            SameValue(GravityStrength, 0, 1.0E-9) and
            ((not (BillowStyle in [tbsBend, tbsSway, tbsFlutter])) or
            (SameValue(BillowDisplacementX, 0, 1.0E-9) and
            SameValue(BillowDisplacementY, 0, 1.0E-9) and
            ((BillowStyle <> tbsFlutter) or
            SameValue(BillowStrength, 0, 1.0E-9)))) then
          begin
            DestinationOffset := (NativeInt(Y) * FWidth + X) * 4;
            PCardinal(@DestinationBytes^[DestinationOffset])^ :=
              PCardinal(@SourceBytes^[DestinationOffset])^;
            Continue;
          end;
        end;
        { A partial selection represents one movable layer.  Even beyond the
          grip falloff it must follow the grips instead of being redrawn at
          its original position. }
        TotalWeight := 1;
        if FullFrameMode then
        begin
          DX := 0;
          DY := 0;
        end
        else
        begin
          DX := AverageGripDX;
          DY := AverageGripDY;
        end;
        FoldShade := 1;
        LiftLight := 1;
      end
      else
      begin
        if FullFrameMode then
        begin
          DX := WeightedDX / TotalWeight * Influence * MaskWeight;
          DY := WeightedDY / TotalWeight * Influence * MaskWeight;
        end
        else
        begin
          { Normalize the grip blend across the complete selected layer.
            Influence still controls folding and lighting, but must not leave
            distant selected pixels behind at the source position. }
          DX := WeightedDX / TotalWeight;
          DY := WeightedDY / TotalWeight;
        end;
        FoldBand := 4 * Influence * (1 - Influence);
        FoldShade := 1 - WeightedForeshortening / TotalWeight *
          GRIP_FOLD_SHADOW_GAIN * FoldBand * MaskWeight * LightingStrength;
        LiftLight := 1 + WeightedForeshortening / TotalWeight *
          GRIP_LIFT_LIGHT_GAIN * Sqr(Influence) * MaskWeight *
          LightingStrength;
      end;
      if (RippleStrength > 0) and (BillowStyle <> tbsFlutter) then
      begin
        Ripple := Ripple * RippleStrength * MaskWeight;
        if BillowStyle in [tbsBend, tbsSway, tbsFlutter] then
          Ripple := Ripple * PartialAnchorBlend;
        DX := DX - RippleDirectionSine * Ripple;
        DY := DY + RippleDirectionCosine * Ripple;
      end;
      if FullFrameMode then
      begin
        SampleX := X - DX + WeightedForeshorteningX / TotalWeight *
          Influence * MaskWeight;
        SampleY := Y - DY + WeightedForeshorteningY / TotalWeight *
          Influence * MaskWeight;
      end
      else
      begin
        SampleX := PartialInverse11 * (X - PartialBX) +
          PartialInverse12 * (Y - PartialBY);
        SampleY := PartialInverse21 * (X - PartialBX) +
          PartialInverse22 * (Y - PartialBY);
        if (RippleStrength > 0) and (BillowStyle <> tbsFlutter) then
        begin
          SampleX := SampleX + RippleDirectionSine * Ripple;
          SampleY := SampleY - RippleDirectionCosine * Ripple;
        end;
        SampleX := X + (SampleX - X) * PartialAnchorBlend;
        SampleY := Y + (SampleY - Y) * PartialAnchorBlend;
      end;
      if BillowStyle in [tbsBend, tbsSway, tbsFlutter] then
      begin
        if BillowStyle = tbsBend then
          BillowBlend := Sqr(PartialAnchorBlend)
        else
          BillowBlend := PartialAnchorBlend * (2 - PartialAnchorBlend);
        { Automatic billow is independent from manual grip deformation.
          Bend concentrates movement near the free edge, while sway uses an
          ease-out curve so most of the hanging cloth follows the motion. }
        SampleX := SampleX - BillowDisplacementX *
          BillowBlend;
        SampleY := SampleY - BillowDisplacementY *
          BillowBlend;
        if BillowStyle = tbsFlutter then
        begin
          FlutterDepthPosition := EnsureRange(PartialAnchorBlend, 0.0, 1.0) *
            FLUTTER_DEPTH_LUT_SIZE;
          FlutterIndex := Trunc(FlutterDepthPosition);
          FlutterIndex1 := Min(FlutterIndex + 1, FLUTTER_DEPTH_LUT_SIZE);
          FlutterDepthFraction := FlutterDepthPosition - FlutterIndex;
          if FFixedEdge in [tfeLeft, tfeRight] then
            FlutterTangentPixel := Y
          else
            FlutterTangentPixel := X;
          FlutterMapOffset0 := NativeInt(FlutterIndex) *
            FlutterTangentLength + FlutterTangentPixel;
          FlutterMapOffset1 := NativeInt(FlutterIndex1) *
            FlutterTangentLength + FlutterTangentPixel;
          FlutterDisplacement :=
            FlutterNormalDisplacementLut[FlutterMapOffset0] *
            (1 - FlutterDepthFraction) +
            FlutterNormalDisplacementLut[FlutterMapOffset1] *
            FlutterDepthFraction;
          FlutterTangentOffset :=
            FlutterTangentOffsetLut[FlutterMapOffset0] *
            (1 - FlutterDepthFraction) +
            FlutterTangentOffsetLut[FlutterMapOffset1] *
            FlutterDepthFraction;
          case FFixedEdge of
            tfeTop:
              begin
                SampleX := SampleX - FlutterTangentOffset;
                SampleY := SampleY - FlutterDisplacement;
              end;
            tfeBottom:
              begin
                SampleX := SampleX - FlutterTangentOffset;
                SampleY := SampleY + FlutterDisplacement;
              end;
            tfeLeft:
              begin
                SampleX := SampleX - FlutterDisplacement;
                SampleY := SampleY - FlutterTangentOffset;
              end;
            tfeRight:
              begin
                SampleX := SampleX + FlutterDisplacement;
                SampleY := SampleY - FlutterTangentOffset;
              end;
          end;
        end;
      end;
      if GravityStrength > 0 then
        SampleY := SampleY - GravityStrength * Sqr(PartialAnchorBlend);
      DestinationOffset := (NativeInt(Y) * FWidth + X) * 4;
      if FullFrameMode and not SameValue(ShrinkRate, 1, 1.0E-9) then
      begin
        { Model the pre-deformation shrink in the inverse lookup so source
          pixels are resampled only once.  Grip origins use the same centered
          scale above, while their pixel offsets retain their configured
          movement distance. }
        SampleX := ImageCenterX + (SampleX - ImageCenterX) / ShrinkRate;
        SampleY := ImageCenterY + (SampleY - ImageCenterY) / ShrinkRate;
      end;
      BoundarySample := FullFrameMode and
        ((SampleX < 0) or (SampleX > FWidth - 1) or
        (SampleY < 0) or (SampleY > FHeight - 1));
      if FullFrameMode and ((SampleX <= -1) or (SampleX >= FWidth) or
        (SampleY <= -1) or (SampleY >= FHeight)) then
      begin
        if not SameValue(ShrinkRate, 1, 1.0E-9) then
          ShadowAlpha := 0
        else
        begin
          OutsideDistance := Max(Max(-SampleX, SampleX - (FWidth - 1)),
            Max(-SampleY, SampleY - (FHeight - 1)));
          ShadowAlpha := EnsureRange(Round(255 * CastShadowStrength *
            Exp(-OutsideDistance / ShadowRadius)), 0, 255);
        end;
        for Channel := 0 to 2 do
          DestinationBytes^[DestinationOffset + Channel] := 0;
        DestinationBytes^[DestinationOffset + 3] := ShadowAlpha;
        Continue;
      end;
      if not FullFrameMode then
      begin
        if (SampleX < 0) or (SampleX > FWidth - 1) or
          (SampleY < 0) or (SampleY > FHeight - 1) then
          Continue;
        MapX0 := Trunc(SampleX);
        MapY0 := Trunc(SampleY);
        MapX1 := Min(MapX0 + 1, FWidth - 1);
        MapY1 := Min(MapY0 + 1, FHeight - 1);
        MapFX := SampleX - MapX0;
        MapFY := SampleY - MapY0;
        if TightPartialCoverage then
        begin
          Weight00 := FTightCoverage[
            (FHeight - 1 - MapY0) * FWidth + MapX0];
          Weight01 := FTightCoverage[
            (FHeight - 1 - MapY0) * FWidth + MapX1];
          Weight10 := FTightCoverage[
            (FHeight - 1 - MapY1) * FWidth + MapX0];
          Weight11 := FTightCoverage[
            (FHeight - 1 - MapY1) * FWidth + MapX1];
        end
        else
        begin
          Weight00 := FCoverage[
            (FHeight - 1 - MapY0) * FWidth + MapX0];
          Weight01 := FCoverage[
            (FHeight - 1 - MapY0) * FWidth + MapX1];
          Weight10 := FCoverage[
            (FHeight - 1 - MapY1) * FWidth + MapX0];
          Weight11 := FCoverage[
            (FHeight - 1 - MapY1) * FWidth + MapX1];
        end;
        MaskWeight := Sqr((Weight00 * (1 - MapFX) + Weight01 * MapFX) *
          (1 - MapFY) + (Weight10 * (1 - MapFX) +
          Weight11 * MapFX) * MapFY);
        if MaskWeight <= 0 then
          Continue;
        FoldShade := 1 + (FoldShade - 1) * MaskWeight *
          PartialAnchorBlend;
        LiftLight := 1 + (LiftLight - 1) * MaskWeight *
          PartialAnchorBlend;
      end;
      if BoundarySample then
      begin
        X0 := Floor(SampleX);
        Y0 := Floor(SampleY);
        X1 := X0 + 1;
        Y1 := Y0 + 1;
        FX := SampleX - X0;
        FY := SampleY - Y0;
        for Channel := 0 to 3 do
          SampledChannels[Channel] :=
            (SourceChannelAt(X0, Y0, Channel) * (1 - FX) +
            SourceChannelAt(X1, Y0, Channel) * FX) * (1 - FY) +
            (SourceChannelAt(X0, Y1, Channel) * (1 - FX) +
            SourceChannelAt(X1, Y1, Channel) * FX) * FY;
      end
      else
      begin
        SampleX := EnsureRange(SampleX, 0.0, FWidth - 1.0);
        SampleY := EnsureRange(SampleY, 0.0, FHeight - 1.0);
        X0 := Trunc(SampleX);
        Y0 := Trunc(SampleY);
        X1 := Min(X0 + 1, FWidth - 1);
        Y1 := Min(Y0 + 1, FHeight - 1);
        FX := SampleX - X0;
        FY := SampleY - Y0;
        PixelOffset00 := (NativeInt(Y0) * FWidth + X0) * 4;
        PixelOffset01 := (NativeInt(Y0) * FWidth + X1) * 4;
        PixelOffset10 := (NativeInt(Y1) * FWidth + X0) * 4;
        PixelOffset11 := (NativeInt(Y1) * FWidth + X1) * 4;
        for Channel := 0 to 3 do
        begin
          Value := (SourceBytes^[PixelOffset00 + Channel] * (1 - FX) +
            SourceBytes^[PixelOffset01 + Channel] * FX) * (1 - FY) +
            (SourceBytes^[PixelOffset10 + Channel] * (1 - FX) +
            SourceBytes^[PixelOffset11 + Channel] * FX) * FY;
          SampledChannels[Channel] := Value;
        end;
      end;
      BacksideGray := (SampledChannels[0] + SampledChannels[1] +
        SampledChannels[2]) / 3;
      BacksideWeight := EnsureRange(WeightedForeshortening / TotalWeight /
        GRIP_MAX_FORESHORTENING * Sqr(Influence) * MaskWeight *
        BacksideStrength * PartialAnchorBlend, 0.0, 1.0);
      for Channel := 0 to 3 do
      begin
        Value := SampledChannels[Channel];
        if Channel < 3 then
        begin
          Value := Value * (1 - GRIP_BACKSIDE_DESATURATION *
            BacksideWeight) + BacksideGray * GRIP_BACKSIDE_DESATURATION *
            BacksideWeight;
          Value := Value * FoldShade * LiftLight *
            (1 - GRIP_BACKSIDE_DARKENING * BacksideWeight);
        end;
        if FullFrameMode then
          DestinationBytes^[DestinationOffset + Channel] :=
            EnsureRange(Round(Value), 0, 255)
        else
          DestinationBytes^[DestinationOffset + Channel] := EnsureRange(
            Round(DestinationBytes^[DestinationOffset + Channel] *
            (1 - MaskWeight) + Value * MaskWeight), 0, 255);
      end;
    end;
  end);
  Result := True;
end;

{$IFDEF DEBUG}
function TShakeDeformationMap.DebugFixedTopBlendAt(X, Y: Integer): Double;
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) or
    (Length(FFixedTopBlend) <> FWidth * FHeight) then
    Exit(1);
  Result := FFixedTopBlend[(FHeight - 1 - Y) * FWidth + X];
end;

procedure TShakeDeformationMap.SaveDebugCoverageBitmap(
  const FileName: string; TightPartialCoverage: Boolean);
var
  Bitmap: Vcl.Graphics.TBitmap;
  Coverage: Byte;
  Row: PByte;
  X: Integer;
  Y: Integer;
begin
  if (FWidth <= 0) or (FHeight <= 0) or
    (Length(FCoverage) <> FWidth * FHeight) then
    Exit;
  Bitmap := Vcl.Graphics.TBitmap.Create;
  try
    Bitmap.PixelFormat := pf32bit;
    Bitmap.SetSize(FWidth, FHeight);
    for Y := 0 to FHeight - 1 do
    begin
      Row := Bitmap.ScanLine[FHeight - 1 - Y];
      for X := 0 to FWidth - 1 do
      begin
        if TightPartialCoverage then
          Coverage := EnsureRange(Round(FTightCoverage[
            (FHeight - 1 - Y) * FWidth + X] * 255), 0, 255)
        else
          Coverage := EnsureRange(Round(FCoverage[
            (FHeight - 1 - Y) * FWidth + X] * 255), 0, 255);
        Row[0] := Coverage;
        Row[1] := Coverage;
        Row[2] := Coverage;
        Row[3] := 255;
        Inc(Row, 4);
      end;
    end;
    Bitmap.SaveToFile(FileName);
  finally
    Bitmap.Free;
  end;
end;
{$ENDIF}

function TShakeDeformationMap.ApplyVariableOuterRgba(Source,
  Destination: Pointer; DisplacementX, DisplacementY: Double;
  out ErrorText: string): Boolean;
type
  PRgbaBytes = ^TRgbaBytes;
  TRgbaBytes = array[0..268435455] of Byte;
var
  AffectedBottom: Integer;
  AffectedLeft: Integer;
  AffectedRight: Integer;
  AffectedTop: Integer;
  BaseX: Double;
  BaseY: Double;
  ByteCount: NativeInt;
  Channel: Integer;
  Coverage: Double;
  DestinationBytes: PRgbaBytes;
  DestinationOffset: NativeInt;
  FX: Double;
  FY: Double;
  InnerMotionRatio: Double;
  PixelOffset00: NativeInt;
  PixelOffset01: NativeInt;
  PixelOffset10: NativeInt;
  PixelOffset11: NativeInt;
  SampleX: Double;
  SampleY: Double;
  ShiftX: Double;
  ShiftY: Double;
  SourceBytes: PRgbaBytes;
  Value: Double;
  Weight: Double;
  WeightX0: Integer;
  WeightX1: Integer;
  WeightY0: Integer;
  WeightY1: Integer;
  X: Integer;
  X0: Integer;
  X1: Integer;
  Y: Integer;
  Y0: Integer;
  Y1: Integer;

  function MapWeight(ScreenX, ScreenY: Integer): Double;
  begin
    if (ScreenX < 0) or (ScreenX >= FWidth) or
      (ScreenY < 0) or (ScreenY >= FHeight) then
      Exit(0);
    Result := FWeights[(FHeight - 1 - ScreenY) * FWidth + ScreenX];
  end;

  function SampleMap(MapX, MapY: Double; CoverageOnly: Boolean): Double;
  var
    W00: Double;
    W01: Double;
    W10: Double;
    W11: Double;
  begin
    if (MapX < 0) or (MapX > FWidth - 1) or
      (MapY < 0) or (MapY > FHeight - 1) then
      Exit(0);
    WeightX0 := Trunc(MapX);
    WeightY0 := Trunc(MapY);
    WeightX1 := Min(WeightX0 + 1, FWidth - 1);
    WeightY1 := Min(WeightY0 + 1, FHeight - 1);
    FX := MapX - WeightX0;
    FY := MapY - WeightY0;
    W00 := MapWeight(WeightX0, WeightY0);
    W01 := MapWeight(WeightX1, WeightY0);
    W10 := MapWeight(WeightX0, WeightY1);
    W11 := MapWeight(WeightX1, WeightY1);
    if CoverageOnly then
    begin
      W00 := Ord(W00 > 0);
      W01 := Ord(W01 > 0);
      W10 := Ord(W10 > 0);
      W11 := Ord(W11 > 0);
    end;
    Result := (W00 * (1 - FX) + W01 * FX) * (1 - FY) +
      (W10 * (1 - FX) + W11 * FX) * FY;
  end;

begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) or (FWidth <= 0) or
    (FHeight <= 0) or (Length(FWeights) <> FWidth * FHeight) then
  begin
    ErrorText := 'MAP_NOT_READY';
    Exit;
  end;

  SourceBytes := Source;
  DestinationBytes := Destination;
  ByteCount := NativeInt(FWidth) * FHeight * 4;
  Move(SourceBytes^, DestinationBytes^, ByteCount);
  if (FActiveRight < FActiveLeft) or (FActiveBottom < FActiveTop) then
  begin
    Result := True;
    Exit;
  end;

  ShiftX := DisplacementX * VARIABLE_OUTER_MOTION_RATIO;
  ShiftY := DisplacementY * VARIABLE_OUTER_MOTION_RATIO;
  InnerMotionRatio := 1 - VARIABLE_OUTER_MOTION_RATIO;
  AffectedLeft := EnsureRange(FActiveLeft + Floor(Min(0.0, ShiftX)),
    0, FWidth - 1);
  AffectedTop := EnsureRange(FActiveTop + Floor(Min(0.0, ShiftY)),
    0, FHeight - 1);
  AffectedRight := EnsureRange(FActiveRight + Ceil(Max(0.0, ShiftX)),
    0, FWidth - 1);
  AffectedBottom := EnsureRange(FActiveBottom + Ceil(Max(0.0, ShiftY)),
    0, FHeight - 1);

  // Evaluate the mask in a coordinate system translated by the outer-edge
  // motion. The remaining displacement grows smoothly toward the center.
  for Y := AffectedTop to AffectedBottom do
    for X := AffectedLeft to AffectedRight do
    begin
      BaseX := X - ShiftX;
      BaseY := Y - ShiftY;
      Weight := SampleMap(BaseX, BaseY, False);
      Coverage := Max(SampleMap(X, Y, True),
        SampleMap(BaseX, BaseY, True));
      if Coverage <= 0 then
        Continue;

      SampleX := EnsureRange(BaseX - DisplacementX *
        InnerMotionRatio * Weight, 0.0, FWidth - 1.0);
      SampleY := EnsureRange(BaseY - DisplacementY *
        InnerMotionRatio * Weight, 0.0, FHeight - 1.0);
      X0 := Trunc(SampleX);
      Y0 := Trunc(SampleY);
      X1 := Min(X0 + 1, FWidth - 1);
      Y1 := Min(Y0 + 1, FHeight - 1);
      FX := SampleX - X0;
      FY := SampleY - Y0;
      PixelOffset00 := (NativeInt(Y0) * FWidth + X0) * 4;
      PixelOffset01 := (NativeInt(Y0) * FWidth + X1) * 4;
      PixelOffset10 := (NativeInt(Y1) * FWidth + X0) * 4;
      PixelOffset11 := (NativeInt(Y1) * FWidth + X1) * 4;
      DestinationOffset := (NativeInt(Y) * FWidth + X) * 4;
      for Channel := 0 to 3 do
      begin
        Value := (SourceBytes^[PixelOffset00 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset01 + Channel] * FX) * (1 - FY) +
          (SourceBytes^[PixelOffset10 + Channel] * (1 - FX) +
          SourceBytes^[PixelOffset11 + Channel] * FX) * FY;
        Value := SourceBytes^[DestinationOffset + Channel] * (1 - Coverage) +
          Value * Coverage;
        DestinationBytes^[DestinationOffset + Channel] :=
          EnsureRange(Round(Value), 0, 255);
      end;
    end;
  Result := True;
end;

class function TShakeStaticDeformer.TryDeform(Source,
  Destination: Vcl.Graphics.TBitmap;
  OuterContour, CenterContour: TShakeCurve;
  DisplacementX, DisplacementY: Double; out ErrorText: string): Boolean;
var
  DeformationMap: TShakeDeformationMap;
begin
  Result := False;
  ErrorText := '';
  if (Source = nil) or (Destination = nil) then
  begin
    ErrorText := 'NO_IMAGE';
    Exit;
  end;
  DeformationMap := TShakeDeformationMap.Create;
  try
    if not DeformationMap.Build(Source.Width, Source.Height,
      OuterContour, CenterContour, ErrorText) then
      Exit;
    Result := DeformationMap.Apply(Source, Destination,
      DisplacementX, DisplacementY, ErrorText);
  finally
    DeformationMap.Free;
  end;
end;

initialization
  InitializeGripWeightLookup;

end.
