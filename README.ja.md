<div align="center">
  <img src="icon/rainy-screen-iOS-Default-1024x1024@1x.png" alt="Rainy Screen アイコン" width="128">
  <h1>Rainy Screen</h1>
  <p>Macのデスクトップに、静かな雨のガラス窓を重ねるアプリ。</p>
  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white" alt="macOS 14以降">
    <img src="https://img.shields.io/badge/Apple%20Silicon-required-5b21b6" alt="Apple Silicon必須">
    <img src="https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white" alt="Swift 6">
    <img src="https://img.shields.io/badge/status-early%20beta-f59e0b" alt="アーリーベータ">
  </p>
  <p><a href="README.md">English</a> · <a href="README.ja.md">日本語</a></p>
</div>

<p align="center">
  <img src="docs/media/rainy-screen-storm-preview.png" alt="Rainy Screen 豪雨プレビュー" width="820">
</p>

Rainy Screenは、接続中のディスプレイに濡れたガラスを重ねるmacOSメニューバーアプリ。現在地または指定地点の天気に連動でき、雨粒は合体・停止・加速しながら流れ、水路やthrough-flowを形成します。カーソルでガラスを拭くこともできます。

## 特徴

| | 内容 |
| --- | --- |
| **天気ガラス** | 天気連動のウェザーモードと、常に雨を表示するレイニーモード。 |
| **液体の動き** | 雨粒ごとにサイズと速度が変わり、合体した水が不規則な水路になります。 |
| **拭き上げ** | カーソルまたはグローバルショートカットでガラスを拭けます。横方向・縦方向に対応。 |
| **複数ディスプレイ** | 全画面または選択したディスプレイだけに表示できます。 |
| **光学表現** | 画面収録、屈折、ぼかし、フレネル反射、色収差で濡れたガラスを表現。 |
| **負荷設定** | 24/30/60 FPSと、ハイクオリティ／バランス／軽量を選択できます。 |

<p align="center">
  <img src="docs/media/rainy-screen-through-flow.png" alt="豪雨時の不規則なthrough-flow" width="49%">
  <img src="docs/media/settings-rain.png" alt="雨の設定画面" width="49%">
</p>

<p align="center"><i>雨の挙動と設定項目はアーリーベータ期間中に変更される可能性があります。</i></p>

## セットアップ

以下の手順でソースからビルドするか、[Releases](https://github.com/u2k8090/rainy-screen/releases)から最新ベータ版をダウンロードできます。配布アプリはad-hoc署名で、公証はされていません。ローカルビルドにApple Developer登録は不要です。

### 必要環境

- Apple Silicon Mac
- macOS 14 Sonoma以降
- Xcode Command Line Tools
- Git

未導入の場合は以下でインストールします。

```sh
xcode-select --install
```

### ビルドと起動

```sh
git clone https://github.com/u2k8090/rainy-screen.git
cd rainy-screen
swift test -c release
./scripts/build.sh
open "dist/preview/Rainy Screen.app"
```

普段使い用のビルドは以下です。

```sh
./scripts/build.sh --install
open "dist/Rainy Screen.app"
```

ビルドスクリプトはアプリバンドルの生成、アイコンの組み込み、ad-hoc署名を行います。リポジトリ外へのインストールは行いません。

## 初回起動

画面収録と位置情報の権限がなくても起動できますが、一部の機能には権限が必要です。

1. メニューバーの **Settings…** を開く。
2. **レイニーモード**を選択して、天気情報なしで雨を試す。
3. 背景の屈折を使う場合は、Rain設定の **背景の屈折・ぼかし** を有効にする。
4. macOSから求められたら、**システム設定 → プライバシーとセキュリティ → 画面収録**でRainy Screenを許可する。
5. **ウェザーモード**で現在地の天気を使う場合だけ、位置情報サービスを許可する。

位置情報を許可せず、指定地点を使うこともできます。画面収録のフレームはメモリ内で処理し、保存・アップロードしません。

<p align="center">
  <img src="docs/media/settings-shortcuts.png" alt="ショートカット設定画面" width="820">
</p>

## 操作

- **ウェザーモード** — Open-Meteoの降雨量・にわか雨量・天気コードから雨の強さを自動調整。手動の雨量・ランダム設定は適用しません。
- **レイニーモード** — 天気に関係なく雨を表示。
- **停止** — オーバーレイを隠し、描画を停止。
- **停止トグルショートカット** — 停止前に選択していたモードへ復帰。
- **拭き上げショートカット** — 登録した修飾キーの組み合わせでガラスを拭く。
- **カーソル効果** — なし・吹き上げ・ブロワーを選択できます。吹き上げは0.5倍から2倍までの5段階で範囲を調整できます。ブロワーではカーソルを中心に雨粒と水路を放射状に飛ばし、5段階の強さで飛ぶ強さ・飛距離・作用範囲・曇りを取る速度を調整できます。一定距離の後は通常の重力・付着力による流れに戻ります。
- **雨の強さ** — レイニーモード用。霧雨から豪雨まで、ランダム切替にも対応。ウェザーモード中は変更できません。
- **吹き上げ設定** — 独立した「吹き上げ」カテゴリで方向と速度を設定。0.25倍・0.5倍・1倍（従来の標準）・2倍・4倍の5段階を保存します。
- **描画品質** — ハイクオリティ、バランス、軽量。軽量設定では衝突計算と軌跡処理を減らします。
- **対象ディスプレイ** — 全画面または保存した個別選択。
- **除外アプリ** — 指定したアプリのウインドウを雨から除外。

固定の停止ショートカットは `Control + Option + Command + R` です。拭き上げと停止トグルのショートカットは設定画面から登録できます。

## プライバシーと権限

- **画面収録**は屈折レイヤー用のデスクトップ画像取得だけに使用します。フレームはメモリ内に留まります。
- **位置情報サービス**は現在地の天気取得だけに使用します。指定地点モードでは不要です。
- **アクセシビリティと入力監視**は使用しません。入力の注入も行いません。
- 天気データは[Open-Meteo](https://open-meteo.com/)から取得します。現在地リクエストの座標は丸めて送信します。

ローカルビルドはad-hoc署名のため、再ビルドやアプリ置換後に画面収録の許可を再設定する必要がある場合があります。

## 開発者向け

```sh
swift test -c release
./scripts/build.sh

'dist/preview/Rainy Screen.app/Contents/MacOS/RainyScreen' --settings-state-test
'dist/preview/Rainy Screen.app/Contents/MacOS/RainyScreen' --settings-smoke-test
'dist/preview/Rainy Screen.app/Contents/MacOS/RainyScreen' --smoke-test --dark-preview
```

スモークテストは合成デスクトップを使用し、実際の画面や位置情報にはアクセスしません。設定画面の画像は`artifacts/settings-preview/`、GPUプレビューは`artifacts/`へ出力されます。

主要モジュールは以下です。

```text
RainCore              物理モデル、雨量、雨粒、合体、水路、拭き上げ
RainRenderer          Metal描画、画面合成、ぼかし、光学表現
Rain.metal            高さ場、屈折、反射、色収差
ScreenCapture         自身を除外したScreenCaptureKit入力
WeatherService        Core LocationとOpen-Meteo連携
SettingsWindow        設定UIと状態同期
```

## 既知の制限

- 現在はApple Siliconのみ対応。
- macOS 14以降が必要。
- 公開版はソース中心で、署名済み・notarize済みのバイナリはまだありません。
- 主要な実機確認は開発者から確認済みの報告があります。天気・権限・スリープ復帰・ログイン起動・ディスプレイ再接続の挙動は、Macの構成によって異なる場合があります。
- 液体モデルはリアルタイム近似であり、Navier–Stokes解析や完全なレイトレーシングではありません。

## コントリビューション

Issue、見た目のフィードバック、再現可能なテストケースを歓迎します。描画の問題を報告する場合は、可能なら以下を添えてください。

- macOSバージョンとMacのモデル
- ディスプレイ枚数と解像度
- 雨の強さと描画品質
- 屈折の有効／無効
- スクリーンショットまたは短い画面収録

変更は小さく保ち、Pull Requestの前に`swift test -c release`を実行してください。

## ライセンス

[MITライセンス](LICENSE)で公開しています。
