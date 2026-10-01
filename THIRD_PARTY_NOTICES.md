# Third Party Notices

shareMK 本体は MIT License です。

このプロジェクトのセットアップ、ビルド、または実行時に利用する主な第三者コンポーネントは以下です。

## Bumble

- Project: https://github.com/google/bumble
- License: Apache License 2.0
- 用途: Bluetooth Classic / HID 関連の実装検証およびセットアップ時の依存パッケージ

## libusb-package

- Project: https://github.com/pyocd/libusb-package
- License: Apache License 2.0
- 用途: Python package として libusb の共有ライブラリを取得するために使用

## libusb

- Project: https://libusb.info/
- License: GNU Lesser General Public License v2.1
- 用途: UB500 USB Bluetooth dongle を macOS から直接制御するために使用

`Scripts/build-app.sh` は `libusb-1.0.dylib` をアプリバンドルへ同梱します。バイナリ配布を行う場合は、LGPL v2.1 の条件に従ってください。

## Realtek RTL8761BU firmware

- Source: linux-firmware project
- 用途: TP-Link UB500 の初期化

firmware バイナリはこのリポジトリには含めていません。`Scripts/setup.sh` がユーザーの環境で取得します。
