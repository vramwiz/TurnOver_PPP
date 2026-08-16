unit Shake_PPP_CurveModel;

interface

uses
  System.Generics.Collections,
  System.Types;

type
  TShakeCurveKind = (sckOuterContour, sckCenterContour);
  TShakeVertexKind = (svkCorner, svkSmooth);
  TTurnOverBillowStyle = (tbsLegacy, tbsBend, tbsSway, tbsFlutter);
  TTurnOverFixedEdge = (tfeTop, tfeBottom, tfeLeft, tfeRight);

  TTurnOverClothSettings = record
    BillowStyle: TTurnOverBillowStyle;
    FixedEdge: TTurnOverFixedEdge;
  end;

  TShakeCurveVertex = record
    Position: TPointF;
    Kind: TShakeVertexKind;
  end;

  TShakeCurve = class
  private
    FClosed: Boolean;
    FVertices: TList<TShakeCurveVertex>;
    function GetCount: Integer;
    function GetVertex(Index: Integer): TShakeCurveVertex;
  public
    constructor Create;
    destructor Destroy; override;
    function AddVertex(const Position: TPointF;
      Kind: TShakeVertexKind): Integer;
    function InsertVertex(Index: Integer; const Position: TPointF;
      Kind: TShakeVertexKind): Integer;
    procedure Assign(Source: TShakeCurve);
    procedure Clear;
    procedure DeleteVertex(Index: Integer);
    procedure SetVertexKind(Index: Integer; Kind: TShakeVertexKind);
    procedure SetVertexPosition(Index: Integer; const Position: TPointF);
    property Closed: Boolean read FClosed write FClosed;
    property Count: Integer read GetCount;
    property Vertices[Index: Integer]: TShakeCurveVertex read GetVertex; default;
  end;

const
  SHAKE_CURVE_SET_COUNT = 2;
  SHAKE_GRIP_POINT_COUNT = 2;

type
  TShakeCurveSet = record
    OuterContour: TShakeCurve;
    CenterContour: TShakeCurve;
  end;
  TShakeCurveSets = array[0..SHAKE_CURVE_SET_COUNT - 1] of TShakeCurveSet;
  TShakeGripPointVertexIndices =
    array[0..SHAKE_GRIP_POINT_COUNT - 1] of Integer;
  TShakeGripVertexIndices = array[0..SHAKE_CURVE_SET_COUNT - 1] of
    TShakeGripPointVertexIndices;
  TShakeGripEnabled = array[0..SHAKE_GRIP_POINT_COUNT - 1] of Boolean;
  TShakeGripPositions = array[0..SHAKE_GRIP_POINT_COUNT - 1] of TPointF;

function TryGetUpperBoundary(Curve: TShakeCurve; out LeftIndex,
  RightIndex, PathStep: Integer): Boolean;
function TryGetFixedBoundary(Curve: TShakeCurve;
  FixedEdge: TTurnOverFixedEdge; out FirstIndex, SecondIndex,
  PathStep: Integer): Boolean;
function IsVertexOnCurvePath(VertexIndex, StartIndex, EndIndex,
  PathStep, VertexCount: Integer): Boolean;
function DefaultTurnOverClothSettings: TTurnOverClothSettings;

implementation

uses
  System.Math;

function DefaultTurnOverClothSettings: TTurnOverClothSettings;
begin
  Result.BillowStyle := tbsLegacy;
  Result.FixedEdge := tfeTop;
end;

function IsVertexOnCurvePath(VertexIndex, StartIndex, EndIndex,
  PathStep, VertexCount: Integer): Boolean;
var
  I: Integer;
  Visited: Integer;
begin
  Result := False;
  if (VertexCount <= 0) or ((PathStep <> 1) and (PathStep <> -1)) then
    Exit;
  I := StartIndex;
  for Visited := 0 to VertexCount - 1 do
  begin
    if I = VertexIndex then
      Exit(True);
    if I = EndIndex then
      Exit;
    I := (I + PathStep + VertexCount) mod VertexCount;
  end;
end;

function TryGetFixedBoundary(Curve: TShakeCurve;
  FixedEdge: TTurnOverFixedEdge; out FirstIndex, SecondIndex,
  PathStep: Integer): Boolean;
var
  ForwardAverageNormal: Double;
  ForwardCount: Integer;
  I: Integer;
  MaximumNormal: Double;
  MinimumNormal: Double;
  Normal: Double;
  ReverseAverageNormal: Double;
  ReverseCount: Integer;
  SideBandLimit: Double;
  Tangent: Double;
  Visited: Integer;

  procedure Coordinates(VertexIndex: Integer; out LocalNormal,
    LocalTangent: Double);
  begin
    case FixedEdge of
      tfeTop:
        begin
          LocalNormal := Curve[VertexIndex].Position.Y;
          LocalTangent := Curve[VertexIndex].Position.X;
        end;
      tfeBottom:
        begin
          LocalNormal := 1 - Curve[VertexIndex].Position.Y;
          LocalTangent := Curve[VertexIndex].Position.X;
        end;
      tfeLeft:
        begin
          LocalNormal := Curve[VertexIndex].Position.X;
          LocalTangent := Curve[VertexIndex].Position.Y;
        end;
    else
      LocalNormal := 1 - Curve[VertexIndex].Position.X;
      LocalTangent := Curve[VertexIndex].Position.Y;
    end;
  end;
begin
  Result := False;
  FirstIndex := -1;
  SecondIndex := -1;
  PathStep := 0;
  if (Curve = nil) or not Curve.Closed or (Curve.Count < 3) then
    Exit;
  MinimumNormal := 1;
  MaximumNormal := 0;
  for I := 0 to Curve.Count - 1 do
  begin
    Coordinates(I, Normal, Tangent);
    MinimumNormal := Min(MinimumNormal, Normal);
    MaximumNormal := Max(MaximumNormal, Normal);
  end;
  SideBandLimit := MinimumNormal + (MaximumNormal - MinimumNormal) * 0.25;
  for I := 0 to Curve.Count - 1 do
  begin
    Coordinates(I, Normal, Tangent);
    if Normal <= SideBandLimit then
    begin
      if FirstIndex < 0 then
        FirstIndex := I
      else
      begin
        Coordinates(FirstIndex, Normal, MaximumNormal);
        if Tangent < MaximumNormal then
          FirstIndex := I;
      end;
      if SecondIndex < 0 then
        SecondIndex := I
      else
      begin
        Coordinates(SecondIndex, Normal, MaximumNormal);
        if Tangent > MaximumNormal then
          SecondIndex := I;
      end;
    end;
  end;
  if (FirstIndex < 0) or (SecondIndex < 0) then
    Exit;
  ForwardAverageNormal := 0;
  ForwardCount := 0;
  I := FirstIndex;
  for Visited := 0 to Curve.Count - 1 do
  begin
    Coordinates(I, Normal, Tangent);
    ForwardAverageNormal := ForwardAverageNormal + Normal;
    Inc(ForwardCount);
    if I = SecondIndex then
      Break;
    I := (I + 1) mod Curve.Count;
  end;
  ReverseAverageNormal := 0;
  ReverseCount := 0;
  I := FirstIndex;
  for Visited := 0 to Curve.Count - 1 do
  begin
    Coordinates(I, Normal, Tangent);
    ReverseAverageNormal := ReverseAverageNormal + Normal;
    Inc(ReverseCount);
    if I = SecondIndex then
      Break;
    I := (I - 1 + Curve.Count) mod Curve.Count;
  end;
  if ForwardAverageNormal / Max(1, ForwardCount) <=
    ReverseAverageNormal / Max(1, ReverseCount) then
    PathStep := 1
  else
    PathStep := -1;
  Result := True;
end;

function TryGetUpperBoundary(Curve: TShakeCurve; out LeftIndex,
  RightIndex, PathStep: Integer): Boolean;
begin
  Result := TryGetFixedBoundary(Curve, tfeTop, LeftIndex, RightIndex,
    PathStep);
end;

constructor TShakeCurve.Create;
begin
  inherited Create;
  FVertices := TList<TShakeCurveVertex>.Create;
end;

destructor TShakeCurve.Destroy;
begin
  FVertices.Free;
  inherited;
end;

function TShakeCurve.AddVertex(const Position: TPointF;
  Kind: TShakeVertexKind): Integer;
var
  Vertex: TShakeCurveVertex;
begin
  Vertex.Position := Position;
  Vertex.Kind := Kind;
  Result := FVertices.Add(Vertex);
end;

function TShakeCurve.InsertVertex(Index: Integer; const Position: TPointF;
  Kind: TShakeVertexKind): Integer;
var
  Vertex: TShakeCurveVertex;
begin
  Result := EnsureRange(Index, 0, FVertices.Count);
  Vertex.Position := Position;
  Vertex.Kind := Kind;
  FVertices.Insert(Result, Vertex);
end;

procedure TShakeCurve.Assign(Source: TShakeCurve);
var
  I: Integer;
begin
  if Source = Self then
    Exit;
  Clear;
  if Source = nil then
    Exit;
  for I := 0 to Source.Count - 1 do
    FVertices.Add(Source[I]);
  FClosed := Source.Closed;
end;

procedure TShakeCurve.Clear;
begin
  FVertices.Clear;
  FClosed := False;
end;

procedure TShakeCurve.DeleteVertex(Index: Integer);
begin
  if (Index < 0) or (Index >= FVertices.Count) then
    Exit;
  FVertices.Delete(Index);
  if FVertices.Count < 3 then
    FClosed := False;
end;

function TShakeCurve.GetCount: Integer;
begin
  Result := FVertices.Count;
end;

function TShakeCurve.GetVertex(Index: Integer): TShakeCurveVertex;
begin
  Result := FVertices[Index];
end;

procedure TShakeCurve.SetVertexPosition(Index: Integer;
  const Position: TPointF);
var
  Vertex: TShakeCurveVertex;
begin
  if (Index < 0) or (Index >= FVertices.Count) then
    Exit;
  Vertex := FVertices[Index];
  Vertex.Position := Position;
  FVertices[Index] := Vertex;
end;

procedure TShakeCurve.SetVertexKind(Index: Integer; Kind: TShakeVertexKind);
var
  Vertex: TShakeCurveVertex;
begin
  if (Index < 0) or (Index >= FVertices.Count) then
    Exit;
  Vertex := FVertices[Index];
  Vertex.Kind := Kind;
  FVertices[Index] := Vertex;
end;

end.
