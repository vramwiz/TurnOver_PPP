object FormShakeSettings: TFormShakeSettings
  Left = 0
  Top = 0
  Caption = #33016#25594#12428#35373#23450
  ClientHeight = 640
  ClientWidth = 960
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnMouseWheel = FormMouseWheel
  OnResize = FormResize
  TextHeight = 15
  object PreviewPaintBox: TPaintBox
    Left = 0
    Top = 64
    Width = 960
    Height = 576
    Align = alClient
    OnDblClick = PreviewPaintBoxDblClick
    OnMouseDown = PreviewPaintBoxMouseDown
    OnMouseMove = PreviewPaintBoxMouseMove
    OnMouseUp = PreviewPaintBoxMouseUp
    OnPaint = PreviewPaintBoxPaint
    ExplicitTop = 56
    ExplicitHeight = 584
  end
  object TopPanel: TPanel
    Left = 0
    Top = 0
    Width = 960
    Height = 64
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object StatusLabel: TLabel
      Left = 12
      Top = 39
      Width = 936
      Height = 17
      AutoSize = False
      Caption = 'No framebuffer has been captured.'
      EllipsisPosition = epEndEllipsis
    end
    object BillowStyleLabel: TLabel
      Left = 518
      Top = 9
      Width = 48
      Height = 15
      Caption = #12394#12403#12365#26041
    end
    object FixedEdgeLabel: TLabel
      Left = 754
      Top = 9
      Width = 36
      Height = 15
      Caption = #22266#23450#36794
    end
    object BillowStyleComboBox: TComboBox
      Left = 574
      Top = 5
      Width = 164
      Height = 23
      Style = csOwnerDrawFixed
      TabOrder = 0
      OnChange = ClothSettingChange
      OnDrawItem = ClothSettingComboDrawItem
    end
    object FixedEdgeComboBox: TComboBox
      Left = 798
      Top = 5
      Width = 92
      Height = 23
      Style = csOwnerDrawFixed
      TabOrder = 1
      OnChange = ClothSettingChange
      OnDrawItem = ClothSettingComboDrawItem
    end
  end
end
