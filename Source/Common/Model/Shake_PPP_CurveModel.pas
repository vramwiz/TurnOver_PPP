unit Shake_PPP_CurveModel;

interface

uses
  System.Generics.Collections,
  System.Types;

type
  TShakeCurveKind = (sckOuterContour, sckCenterContour);
  TShakeVertexKind = (svkCorner, svkSmooth);

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
function IsVertexOnCurvePath(VertexIndex, StartIndex, EndIndex,
  PathStep, VertexCount: Integer): Boolean;

implementation

uses
  System.Math;

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

function TryGetUpperBoundary(Curve: TShakeCurve; out LeftIndex,
  RightIndex, PathStep: Integer): Boolean;
var
  ForwardAverageY: Double;
  ForwardCount: Integer;
  I: Integer;
  MaximumY: Double;
  MinimumY: Double;
  ReverseAverageY: Double;
  ReverseCount: Integer;
  TopBandLimit: Double;
  Visited: Integer;
begin
  Result := False;
  LeftIndex := -1;
  RightIndex := -1;
  PathStep := 0;
  if (Curve = nil) or not Curve.Closed or (Curve.Count < 3) then
    Exit;
  MinimumY := 1;
  MaximumY := 0;
  for I := 0 to Curve.Count - 1 do
  begin
    MinimumY := Min(MinimumY, Curve[I].Position.Y);
    MaximumY := Max(MaximumY, Curve[I].Position.Y);
  end;
  TopBandLimit := MinimumY + (MaximumY - MinimumY) * 0.25;
  for I := 0 to Curve.Count - 1 do
    if Curve[I].Position.Y <= TopBandLimit then
    begin
      if (LeftIndex < 0) or
        (Curve[I].Position.X < Curve[LeftIndex].Position.X) then
        LeftIndex := I;
      if (RightIndex < 0) or
        (Curve[I].Position.X > Curve[RightIndex].Position.X) then
        RightIndex := I;
    end;
  if (LeftIndex < 0) or (RightIndex < 0) then
    Exit;
  ForwardAverageY := 0;
  ForwardCount := 0;
  I := LeftIndex;
  for Visited := 0 to Curve.Count - 1 do
  begin
    ForwardAverageY := ForwardAverageY + Curve[I].Position.Y;
    Inc(ForwardCount);
    if I = RightIndex then
      Break;
    I := (I + 1) mod Curve.Count;
  end;
  ReverseAverageY := 0;
  ReverseCount := 0;
  I := LeftIndex;
  for Visited := 0 to Curve.Count - 1 do
  begin
    ReverseAverageY := ReverseAverageY + Curve[I].Position.Y;
    Inc(ReverseCount);
    if I = RightIndex then
      Break;
    I := (I - 1 + Curve.Count) mod Curve.Count;
  end;
  if ForwardAverageY / Max(1, ForwardCount) <=
    ReverseAverageY / Max(1, ReverseCount) then
    PathStep := 1
  else
    PathStep := -1;
  Result := True;
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
