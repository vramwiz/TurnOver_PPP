# TurnOver_PPP 作業ノート

## 目的

このファイルは、TurnOver_PPPの共通基盤、ビルド・配備規則、実装・保守ルールをまとめる。プラグイン固有の動作仕様は、仕様確定後に別途追加する。

## 現在の状態

- `D:\DelphiProg\Shake_PPP`を初期雛形として複製した。
- プロジェクト名とメインファイル名は`TurnOver_PPP`とする。
- Shake_PPP由来のユニット名と動作固有コードは、不要機能を整理する後工程まで残す。
- 現在の作業ではビルドとAviUtl2の起動・操作を行わない。

## 共通ライブラリ

TurnOver_PPPは次のSyncroh2共通ユニットを直接参照する。`TurnOver_PPP`と`Syncroh2`は同じ親フォルダーに配置する。

- `..\Syncroh2\AviUtl\Filter\AviUtl2FilterTypes.pas`
  - AviUtl2フィルターSDK型定義
- `..\Syncroh2\AviUtl\Filter\AviUtl2FilterInfoUtils.pas`
  - フレーム、時刻、FPS、画像オブジェクト座標の取得
- `..\Syncroh2\Plugin_Filter\PluginFilterTable.pas`
  - 設定項目と`TFILTER_PLUGIN_TABLE`の登録

共通化できるSDK定義、登録処理、オブジェクト情報取得をプラグイン側に重複実装しない。共通ユニットのABI型定義を変更する場合は、C/C++側SDKとフィールド順、型、アラインメントを照合する。

## プロジェクト構成

- `TurnOver_PPP.dpr`
  - DLLエクスポート境界と使用ユニットを定義する。
- `TurnOver_PPP.dproj`
  - Win64 Debug／Release、出力先、配備処理を定義する。
- `Source\Plugin\Filter`
  - フィルター登録、コールバック、専用GUIの入口を置く。
- `Source\Common`
  - プラグイン内で責務別に分離したモデル、設定、描画、診断を置く。
- `Tests`
  - AviUtl2を起動せずに検証できる単体テストとスモークテストを置く。

## 共通ビルドルール

- Delphi 37.0を使用する。
- 対象プラットフォームはWin64のみとする。
- DebugとReleaseの両構成を保つ。
- 原則としてコンパイル警告0、エラー0で完了とする。
- ビルド前に`C:\ProgramData\aviutl2\Plugin\TurnOver_PPP`がなければ作成する。
- DebugはDLLを`TurnOver_PPP.auf2`へコピーし、調査用のDLLとRSMを残す。
- ReleaseはDLLを`TurnOver_PPP.auf2`へコピーした後、同じ出力先のDLLとRSMを削除する。

Debug Win64:

```powershell
cmd /c "call ""C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"" && msbuild ""D:\DelphiProg\TurnOver_PPP\TurnOver_PPP.dproj"" /t:Build /p:Config=Debug /p:Platform=Win64"
```

Release Win64:

```powershell
cmd /c "call ""C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"" && msbuild ""D:\DelphiProg\TurnOver_PPP\TurnOver_PPP.dproj"" /t:Build /p:Config=Release /p:Platform=Win64"
```

配備先:

```text
C:\ProgramData\aviutl2\Plugin\TurnOver_PPP\TurnOver_PPP.auf2
```

## 実装・保守ルール

- フィルターコールバック境界からDelphi例外を外へ漏らさない。
- 毎フレーム処理でファイル再読込、不要なメモリ確保、GUI値の書き戻しを行わない。
- 状態をオブジェクト別に保持する場合は、並列コールバックと破棄時の排他制御を考慮する。
- コメントは処理の言い換えではなく、目的、責務、注意点、状態や値の意味を補う。
- 責務が増えたら専用ユニットへ分け、グローバルな可変状態を避ける。
- Debugのみ`C:\ProgramData\aviutl2\Plugin\TurnOver_PPP\TurnOver_PPP_debug.log`へ診断ログを出力してよい。Releaseでは出力しない。

## Git管理ルール

- `.pas`、`.dfm`、`.dpr`、`.dproj`、`.res`、文書、配布・検証に必要なスクリプトと素材を管理する。
- `Win32`、`Win64`、`.dcu`、`.rsm`、`.dll`、`.auf2`、IDEローカル設定、履歴・復旧データは管理しない。
- Pascal、プロジェク、文書の改行は`.gitattributes`に従う。
- `.res`などのバイナリーファイルはbinaryとして扱う。

## 作業ログ

- 2026-08-11: Shake_PPPからTurnOver_PPPを複製し、メインプロジェクトファイルを`TurnOver_PPP.dpr`・`TurnOver_PPP.dproj`・`TurnOver_PPP.res`へ改名した。Debug／Releaseの出力先とビルド後コピー先を`C:\ProgramData\aviutl2\Plugin\TurnOver_PPP`へ変更した。指示に従いビルドとAviUtl2の起動は行っていない。
