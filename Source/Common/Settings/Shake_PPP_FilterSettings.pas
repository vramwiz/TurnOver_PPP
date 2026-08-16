unit Shake_PPP_FilterSettings;

// Owns the animatable grip offsets and turnover appearance controls.

interface

uses
  Shake_PPP_CurveModel,
  AviUtl2FilterTypes;

type
  TTurnOverRuntimeSettings = record
    AnimationSpeed: Double;
    BacksideStrength: Double;
    CastShadowStrength: Double;
    FoldStrength: Double;
    GravityStrength: Double;
    GripOffsets: TShakeGripPositions;
    InfluenceRadius: Double;
    LightingStrength: Double;
    RippleCount: Double;
    RippleStrength: Double;
    ShrinkRate: Double;
    WindDirectionDegrees: Double;
    WindPeriod: Double;
    WindStrength: Double;
    WindTurbulence: Double;
  end;

var
  Grip1XItem: TFILTER_ITEM_TRACK;
  Grip1YItem: TFILTER_ITEM_TRACK;
  Grip2XItem: TFILTER_ITEM_TRACK;
  Grip2YItem: TFILTER_ITEM_TRACK;
  FoldStrengthItem: TFILTER_ITEM_TRACK;
  GravityStrengthItem: TFILTER_ITEM_TRACK;
  LightingStrengthItem: TFILTER_ITEM_TRACK;
  BacksideStrengthItem: TFILTER_ITEM_TRACK;
  CastShadowStrengthItem: TFILTER_ITEM_TRACK;
  InfluenceRadiusItem: TFILTER_ITEM_TRACK;
  WindPeriodItem: TFILTER_ITEM_TRACK;
  WindStrengthItem: TFILTER_ITEM_TRACK;
  WindDirectionItem: TFILTER_ITEM_TRACK;
  WindTurbulenceItem: TFILTER_ITEM_TRACK;
  RippleCountItem: TFILTER_ITEM_TRACK;
  RippleStrengthItem: TFILTER_ITEM_TRACK;
  ShrinkRateItem: TFILTER_ITEM_TRACK;
  AnimationSpeedItem: TFILTER_ITEM_TRACK;

procedure AddTurnOverFilterItems;
function CurrentTurnOverRuntimeSettings: TTurnOverRuntimeSettings;

implementation

uses
  PluginFilterTable;

procedure AddTurnOverFilterItems;
begin
  AddTrack(Grip1XItem, 'つまみ1 X', 0.0, -2000.0, 2000.0, 1.0);
  AddTrack(Grip1YItem, 'つまみ1 Y', 0.0, -2000.0, 2000.0, 1.0);
  AddTrack(Grip2XItem, 'つまみ2 X', 0.0, -2000.0, 2000.0, 1.0);
  AddTrack(Grip2YItem, 'つまみ2 Y', 0.0, -2000.0, 2000.0, 1.0);
  AddTrack(ShrinkRateItem, '縮小率', 100.0, 10.0, 100.0, 1.0);
  AddTrack(GravityStrengthItem, '重力', 0.0, 0.0, 500.0, 1.0);
  AddTrack(WindStrengthItem, '風', 0.0, 0.0, 500.0, 1.0);
  AddTrack(WindPeriodItem, '周期', 60.0, 1.0, 600.0, 1.0);
  AddTrack(WindDirectionItem, '風向', 0.0, -180.0, 180.0, 1.0);
  AddTrack(WindTurbulenceItem, '乱れ', 0.0, 0.0, 100.0, 1.0);
  AddTrack(RippleStrengthItem, '波打ち', 0.0, 0.0, 200.0, 1.0);
  AddTrack(RippleCountItem, '波数', 2.0, 1.0, 10.0, 0.1);
  AddTrack(InfluenceRadiusItem, '影響範囲', 38.0, 5.0, 100.0, 1.0);
  AddTrack(FoldStrengthItem, '折れ', 100.0, 0.0, 200.0, 1.0);
  AddTrack(LightingStrengthItem, '陰影', 100.0, 0.0, 200.0, 1.0);
  AddTrack(BacksideStrengthItem, '裏面', 35.0, 0.0, 100.0, 1.0);
  AddTrack(CastShadowStrengthItem, '落影', 25.0, 0.0, 100.0, 1.0);
  { Keep new tracks at the end so existing project item indices remain valid. }
  AddTrack(AnimationSpeedItem, '速度', 100.0, 0.0, 400.0, 1.0);
end;

function CurrentTurnOverRuntimeSettings: TTurnOverRuntimeSettings;
begin
  Result.AnimationSpeed := AnimationSpeedItem.Value / 100;
  Result.GripOffsets[0].X := Grip1XItem.Value;
  Result.GripOffsets[0].Y := Grip1YItem.Value;
  Result.GripOffsets[1].X := Grip2XItem.Value;
  Result.GripOffsets[1].Y := Grip2YItem.Value;
  Result.ShrinkRate := ShrinkRateItem.Value / 100;
  Result.GravityStrength := GravityStrengthItem.Value;
  Result.WindStrength := WindStrengthItem.Value;
  Result.WindPeriod := WindPeriodItem.Value;
  Result.WindDirectionDegrees := WindDirectionItem.Value;
  Result.WindTurbulence := WindTurbulenceItem.Value / 100;
  Result.RippleStrength := RippleStrengthItem.Value;
  Result.RippleCount := RippleCountItem.Value;
  Result.InfluenceRadius := InfluenceRadiusItem.Value / 100;
  Result.FoldStrength := FoldStrengthItem.Value / 100;
  Result.LightingStrength := LightingStrengthItem.Value / 100;
  Result.BacksideStrength := BacksideStrengthItem.Value / 100;
  Result.CastShadowStrength := CastShadowStrengthItem.Value / 100;
end;

end.
