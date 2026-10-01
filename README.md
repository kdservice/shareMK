# shareMK

shareMK は、Mac を Bluetooth HID キーボード/マウスとして見せ、Windows や Linux に入力を送る macOS メニューバーアプリです。

現時点では、Mac に挿した TP-Link UB500 を直接制御する前提の実験的な実装です。

## 事前準備

- macOS 13 以降
- Xcode または Xcode Command Line Tools
- Python 3
- TP-Link UB500
- セットアップ時に Python パッケージと Realtek RTL8761BU firmware を取得できるネットワーク接続

macOS の入力監視は初回起動時に許可してください。許可後に入力が取れない場合は、shareMK を一度終了して再起動してください。

## セットアップ

```sh
./Scripts/setup.sh
```

このスクリプトは以下を準備します。

- `.build/ub500-venv`
- Bumble と libusb-package
- `.build/ub500-firmware/rtl8761bu_fw.bin`
- `.build/ub500-firmware/rtl8761bu_config.bin`

## ビルド

```sh
./Scripts/build-app.sh
```

生成先は以下です。

```text
dist/shareMK.app
```

通常は ad-hoc 署名でビルドします。開発者証明書で署名する場合は `CODESIGN_IDENTITY` を指定してください。

```sh
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build-app.sh
```

## 実行

```sh
open dist/shareMK.app
```

必要に応じて `/Applications` にコピーしてください。

## ライセンス

shareMK 本体は MIT License です。詳しくは `LICENSE` を参照してください。

利用ライブラリと関連コンポーネントは `THIRD_PARTY_NOTICES.md` に分けて記載しています。

## 公開パッケージに含めているもの

- `Sources/`
- `Resources/`
- `Scripts/setup.sh`
- `Scripts/build-app.sh`
- `README.md`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`
- `.gitignore`

診断用コード、テスト用コード、ローカルビルド生成物、古い実装メモは含めていません。
