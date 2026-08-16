program CurveDataRoundTrip;

{$APPTYPE CONSOLE}

uses
  System.Math,
  System.SysUtils,
  System.Types,
  Shake_PPP_CurveModel in 'Source\Common\Model\Shake_PPP_CurveModel.pas',
  Shake_PPP_CurveData in 'Source\Common\Model\Shake_PPP_CurveData.pas';

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise Exception.Create(MessageText);
end;

var
  BoundaryCurve: TShakeCurve;
  Center: TShakeCurve;
  ClothSettings: TTurnOverClothSettings;
  DecodedCenter: TShakeCurve;
  DecodedClothSettings: TTurnOverClothSettings;
  DecodedGrips: TShakeGripVertexIndices;
  DecodedOuter: TShakeCurve;
  DecodedSets: TShakeCurveSets;
  ErrorText: string;
  I: Integer;
  FirstBoundaryIndex: Integer;
  InvalidText: string;
  J: Integer;
  LegacyGripText: string;
  LegacyTurnOverText: string;
  OldText: string;
  Outer: TShakeCurve;
  BoundaryPathStep: Integer;
  SecondBoundaryIndex: Integer;
  Grips: TShakeGripVertexIndices;
  Sets: TShakeCurveSets;
  Text: string;
  TurnOverGrips: TShakeGripPointVertexIndices;
  DecodedTurnOverGrips: TShakeGripPointVertexIndices;
begin
  BoundaryCurve := TShakeCurve.Create;
  Outer := TShakeCurve.Create;
  Center := TShakeCurve.Create;
  DecodedOuter := TShakeCurve.Create;
  DecodedCenter := TShakeCurve.Create;
  Sets[0].OuterContour := Outer;
  Sets[0].CenterContour := Center;
  Sets[1].OuterContour := TShakeCurve.Create;
  Sets[1].CenterContour := TShakeCurve.Create;
  for I := 0 to SHAKE_CURVE_SET_COUNT - 1 do
  begin
    DecodedSets[I].OuterContour := TShakeCurve.Create;
    DecodedSets[I].CenterContour := TShakeCurve.Create;
    for J := 0 to SHAKE_GRIP_POINT_COUNT - 1 do
    begin
      Grips[I, J] := -1;
      DecodedGrips[I, J] := -1;
    end;
  end;
  try
    BoundaryCurve.AddVertex(PointF(0, 0), svkCorner);
    BoundaryCurve.AddVertex(PointF(1, 0), svkCorner);
    BoundaryCurve.AddVertex(PointF(1, 1), svkCorner);
    BoundaryCurve.AddVertex(PointF(0, 1), svkCorner);
    BoundaryCurve.Closed := True;
    Require(TryGetFixedBoundary(BoundaryCurve, tfeTop,
      FirstBoundaryIndex, SecondBoundaryIndex, BoundaryPathStep) and
      (FirstBoundaryIndex = 0) and (SecondBoundaryIndex = 1) and
      (BoundaryPathStep = 1), 'Top fixed boundary was detected incorrectly.');
    Require(TryGetFixedBoundary(BoundaryCurve, tfeBottom,
      FirstBoundaryIndex, SecondBoundaryIndex, BoundaryPathStep) and
      (FirstBoundaryIndex = 3) and (SecondBoundaryIndex = 2) and
      (BoundaryPathStep = -1),
      'Bottom fixed boundary was detected incorrectly.');
    Require(TryGetFixedBoundary(BoundaryCurve, tfeLeft,
      FirstBoundaryIndex, SecondBoundaryIndex, BoundaryPathStep) and
      (FirstBoundaryIndex = 0) and (SecondBoundaryIndex = 3) and
      (BoundaryPathStep = -1), 'Left fixed boundary was detected incorrectly.');
    Require(TryGetFixedBoundary(BoundaryCurve, tfeRight,
      FirstBoundaryIndex, SecondBoundaryIndex, BoundaryPathStep) and
      (FirstBoundaryIndex = 1) and (SecondBoundaryIndex = 2) and
      (BoundaryPathStep = 1), 'Right fixed boundary was detected incorrectly.');
    Outer.AddVertex(PointF(0.1, 0.2), svkSmooth);
    Outer.AddVertex(PointF(0.8, 0.25), svkCorner);
    Outer.AddVertex(PointF(0.55, 0.9), svkSmooth);
    Outer.Closed := True;
    Center.AddVertex(PointF(0.3, 0.4), svkCorner);
    Center.AddVertex(PointF(0.6, 0.7), svkSmooth);

    Require(TryEncodeCurveData(Outer, Center, Text, ErrorText), ErrorText);
    OldText := Text;
    Require(Pos(#10, Text) = 0, 'Serialized data must stay on one line.');
    Require(TryDecodeCurveData(Text, DecodedOuter, DecodedCenter,
      ErrorText), ErrorText);
    Require(DecodedOuter.Closed, 'Outer closed state was not restored.');
    Require(DecodedOuter.Count = 3, 'Outer vertex count changed.');
    Require(DecodedCenter.Count = 2, 'Center vertex count changed.');
    Require(DecodedOuter[1].Kind = svkCorner, 'Vertex kind changed.');
    Require(SameValue(DecodedOuter[2].Position.Y, 0.9, 0.000001),
      'Coordinate changed.');

    Sets[1].OuterContour.AddVertex(PointF(0.2, 0.3), svkCorner);
    Sets[1].CenterContour.AddVertex(PointF(0.7, 0.6), svkSmooth);
    Require(TryEncodeCurveSets(Sets, Text, ErrorText), ErrorText);
    Require(Text.StartsWith('SPP2|'), 'Two-set format prefix is invalid.');
    Require(TryDecodeCurveSets(Text, DecodedSets, ErrorText), ErrorText);
    Require(DecodedSets[0].OuterContour.Count = 3,
      'Set 1 outer curve changed.');
    Require(DecodedSets[1].OuterContour.Count = 1,
      'Set 2 outer curve changed.');
    Require(DecodedSets[1].CenterContour[0].Kind = svkSmooth,
      'Set 2 center vertex kind changed.');
    Grips[0, 0] := 0;
    Grips[0, 1] := 2;
    Grips[1, 0] := 0;
    Require(TryEncodeCurveSets(Sets, Grips, Text, ErrorText), ErrorText);
    LegacyGripText := Text;
    Require(Text.StartsWith('SPP3|'), 'Grip format prefix is invalid.');
    Require(TryDecodeCurveSets(Text, DecodedSets, DecodedGrips,
      ErrorText), ErrorText);
    Require((DecodedGrips[0, 0] = 0) and (DecodedGrips[0, 1] = 2) and
      (DecodedGrips[1, 0] = 0) and (DecodedGrips[1, 1] = -1),
      'Grip assignments changed.');
    InvalidText := StringReplace(Text, '1G,0,2', '1G,0,0', []);
    Require(not TryDecodeCurveSets(InvalidText, DecodedSets, DecodedGrips,
      ErrorText), 'Duplicate grip assignments were accepted.');
    Require((DecodedGrips[0, 0] = 0) and (DecodedGrips[0, 1] = 2),
      'Malformed grip data modified the current assignments.');
    TurnOverGrips[0] := 0;
    TurnOverGrips[1] := 2;
    ClothSettings.BillowStyle := tbsFlutter;
    ClothSettings.FixedEdge := tfeLeft;
    DecodedTurnOverGrips[0] := -1;
    DecodedTurnOverGrips[1] := -1;
    DecodedClothSettings := DefaultTurnOverClothSettings;
    Require(TryEncodeTurnOverCurveData(Outer, TurnOverGrips, ClothSettings,
      Text, ErrorText), ErrorText);
    Require(Text.StartsWith('TPP2|'), 'TurnOver format prefix is invalid.');
    Require(TryDecodeTurnOverCurveData(Text, DecodedOuter,
      DecodedTurnOverGrips, DecodedClothSettings, ErrorText), ErrorText);
    Require((DecodedOuter.Count = 3) and (DecodedTurnOverGrips[0] = 0) and
      (DecodedTurnOverGrips[1] = 2), 'TurnOver data changed.');
    Require((DecodedClothSettings.BillowStyle = tbsFlutter) and
      (DecodedClothSettings.FixedEdge = tfeLeft),
      'TurnOver cloth settings changed.');
    InvalidText := StringReplace(Text, '|B,3,2', '|B,9,2', []);
    Require(not TryDecodeTurnOverCurveData(InvalidText, DecodedOuter,
      DecodedTurnOverGrips, DecodedClothSettings, ErrorText),
      'Invalid TurnOver cloth settings were accepted.');
    Require((DecodedOuter.Count = 3) and
      (DecodedClothSettings.BillowStyle = tbsFlutter) and
      (DecodedClothSettings.FixedEdge = tfeLeft),
      'Invalid cloth settings modified the current data.');
    Require(TryDecodeCurveSets(Text, DecodedSets, ErrorText), ErrorText);
    Require((DecodedSets[0].OuterContour.Count = 3) and
      (DecodedSets[1].OuterContour.Count = 0),
      'Runtime compatibility conversion for TPP2 failed.');
    LegacyTurnOverText := Text.Substring(0, Text.LastIndexOf('|'));
    LegacyTurnOverText := 'TPP1' + LegacyTurnOverText.Substring(4);
    DecodedClothSettings.BillowStyle := tbsSway;
    DecodedClothSettings.FixedEdge := tfeRight;
    Require(TryDecodeTurnOverCurveData(LegacyTurnOverText, DecodedOuter,
      DecodedTurnOverGrips, DecodedClothSettings, ErrorText), ErrorText);
    Require((DecodedClothSettings.BillowStyle = tbsLegacy) and
      (DecodedClothSettings.FixedEdge = tfeTop),
      'TPP1 did not receive default cloth settings.');
    Require(TryDecodeTurnOverCurveData(LegacyGripText, DecodedOuter,
      DecodedTurnOverGrips, DecodedClothSettings, ErrorText), ErrorText);
    Require((DecodedTurnOverGrips[0] = 0) and
      (DecodedTurnOverGrips[1] = 2),
      'SPP3 to TurnOver compatibility conversion failed.');
    Require((DecodedClothSettings.BillowStyle = tbsLegacy) and
      (DecodedClothSettings.FixedEdge = tfeTop),
      'SPP3 did not receive default cloth settings.');
    Require(TryDecodeCurveSets(OldText, DecodedSets, DecodedGrips,
      ErrorText), ErrorText);
    Require((DecodedSets[0].OuterContour.Count = 3) and
      (DecodedSets[1].OuterContour.Count = 0),
      'SPP1 compatibility conversion failed.');
    Require((DecodedGrips[0, 0] = -1) and (DecodedGrips[0, 1] = -1),
      'SPP1 compatibility did not clear grip assignments.');
    Require(TryDecodeTurnOverCurveData(OldText, DecodedOuter,
      DecodedTurnOverGrips, ErrorText), ErrorText);
    Require((DecodedOuter.Count = 3) and
      (DecodedTurnOverGrips[0] = -1) and
      (DecodedTurnOverGrips[1] = -1),
      'SPP1 to TurnOver compatibility conversion failed.');

    Require(not TryDecodeCurveData('SPP1|O,1;bad|C,0',
      DecodedOuter, DecodedCenter, ErrorText),
      'Malformed data was accepted.');
    Require(DecodedOuter.Count = 3,
      'Malformed data modified the current curve.');
    Require(TryDecodeCurveData('', DecodedOuter, DecodedCenter,
      ErrorText), ErrorText);
    Require((DecodedOuter.Count = 0) and (DecodedCenter.Count = 0),
      'Empty data did not clear the curves.');
    Writeln('CurveDataRoundTrip: PASS');
  finally
    for I := SHAKE_CURVE_SET_COUNT - 1 downto 0 do
    begin
      DecodedSets[I].CenterContour.Free;
      DecodedSets[I].OuterContour.Free;
    end;
    Sets[1].CenterContour.Free;
    Sets[1].OuterContour.Free;
    DecodedCenter.Free;
    DecodedOuter.Free;
    Center.Free;
    Outer.Free;
    BoundaryCurve.Free;
  end;
end.
