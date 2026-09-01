# PiKVM-Docker

[English](README.md)

PiKVM の kvmd をコンテナで動かし、複数のターゲットを切り替えるためのビルドスクリプトと設定です。

すでに数個のコンテナが動いている Raspberry Pi が手元にあり、かつ OS が起動するまでキーボードと画面を必要とする Windows マシンが何台かあったので、新しいPiやKVMを買うことなく、1つのPiにKVMを集約できたらおもしろいな、と思い作りました。

## 機能

- **Web UI からターゲットを切り替えられます** ターゲットごとにボタンが1つ並びます。接続は数秒間切れて、自動的につながり直します。Web UI で調整したストリームや HID の設定は切り替えのたびに戻るため、維持したい設定は `config/override.yaml` に書いてください。
- **起動できないターゲットは起動時にスキップします** デバイスを開けなかったターゲットは除外され、起動が失敗してループすることはありません。
- **選択中のターゲットを記憶します** 再起動や再ビルドをまたいでも保持されます。そのデバイスが使えなくなった場合は、先頭の使用可能なターゲットへ切り替わります。
- **特権なしで動作します** `--privileged` も追加の Linux ケーパビリティも使いません。[OTG モード](#otg-モード)を有効にする場合のみ必要です。
- **[ATX 電源制御](#atx-電源制御)**（任意）。ターゲットの電源投入、強制切断、リセットが行えます。
- **[OTG モード](#otg-モード)**（任意）。ディスクイメージを USB ドライブとしてマシンに見せられます。

## 動作環境

- Raspberry Pi 4 (b) または 5、aarch64、USB HDMI キャプチャ構成（`hdmiusb` プラットフォーム）。
- ターゲット1台につき、USB HDMI キャプチャドングル1個と CH9329 USB シリアル HID アダプタ1個。
- **Docker 28.0.0 以降**。`docker version --format '{{.Server.Version}}'` で確認できます。
- cgroup v2。`stat -fc %T /sys/fs/cgroup` が `cgroup2fs` を返す必要があります。

## ビルド

PiKVM が公開しているディスクイメージから rootfs を取り出します。root で実行してください。

```sh
sudo ./build.sh --platform v2-hdmiusb-rpi4   # または v2-hdmiusb-rpi5
```

`--version` を指定すると、最新版ではなく特定のリリースをビルドできます。公開されている日付は [files.pikvm.org](https://files.pikvm.org/images/) に一覧があります。更新を取り消したい場合も、以前の日付を指定して同じ手順を実行します。設定、ログイン情報、選択中のターゲットはそのまま残ります。

```sh
sudo ./build.sh --platform v2-hdmiusb-rpi4 --version 20260831
docker compose up -d --build
```

すでに手元にあるファイルからビルドする場合は、`--image` に渡します。

```sh
sudo ./build.sh --image ~/v2-hdmiusb-rpi4-aarch64-20260831.img.xz
```

## 使い方

### 1. ターゲットと設定ファイルを用意する

```sh
cd config
cp targets.conf.example targets.conf
cp override.yaml.example override.yaml
vim targets.conf
```

`targets.conf` の書き方は [targets.conf の書き方](#targetsconf-の書き方)を参照してください。`override.yaml` はこの環境固有の kvmd 設定を書くファイルで、空のままでも構いません。書ける項目は PiKVM の[設定ドキュメント](https://docs.pikvm.org/config/)に一覧があります。

### 2. 起動する

```sh
docker compose up -d
```

Web UI はデフォルトで `https://<Pi のアドレス>:8443/` で開きます。ポートは `compose.yml` で変更できます。

初期ログインは `admin` / `admin` です。管理下にないネットワークから到達できるようにする前に変更してください。

```sh
docker exec -it pikvm kvmd-htpasswd set admin
```

変更したパスワードは `pikvm-state` ボリュームに書き込まれます。そのため再起動や再ビルドをまたいでも保持され、このボリュームを削除すると失われます。二要素認証を含め、詳細は PiKVM の[認証ドキュメント](https://docs.pikvm.org/auth/#changing-the-kvm-password)を参照してください。

ターゲットを追加または変更する場合は、`config/targets.conf` を編集して `docker compose restart` を実行してください。

## targets.conf の書き方

1行に1ターゲットを記述し、列は空白で区切ります。`#` から先はコメントとして扱われ、空行は無視されます。

| 列 | 説明 |
| :--- | :--- |
| `<name>` | `^[a-z0-9][a-z0-9-]*$` に一致する必要があります。 |
| `<video-device>` | キャプチャデバイスの `by-path` 名を、ホスト上での表記どおりに書きます。 |
| `<hid-device>` | CH9329 アダプタの `by-id` 名を、ホスト上での表記どおりに書きます。 |
| `[label]` | 任意。Web UI のボタンに表示する文字列です。行の残り全体を使うため、空白や日本語を含められます。省略した場合は `<name>` になります。 |

```
# name       video device                                                     hid device                                        label
workstation  /dev/v4l/by-path/platform-xhci-hcd.1-usb-0:1.4:1.0-video-index0  /dev/serial/by-id/usb-1a86_USB_Serial-if00-port0  ワークステーション
nas          /dev/v4l/by-path/platform-xhci-hcd.1-usb-0:1.3:1.0-video-index0  /dev/serial/by-id/usb-Prolific_Tech...-if00-port0  ファイルサーバー
```

最初に書いたターゲットが既定になります。初回起動時に選択されるほか、直前まで使っていたターゲットのデバイスが使えなくなった場合にも選択されます。

ホスト上の名前は `ls -l /dev/v4l/by-path/` と `ls -l /dev/serial/by-id/` で確認し、表示されたとおりに書いてください。`/dev/video0` や `/dev/ttyUSB0` は認識順に割り当てられるため、抜き差しや再起動によって別のターゲットのハードウェアを指すことがあるため使用しないでください。

## ターゲットごとに変えられるもの

ターゲットごとに画面・キーボード・マウスを持てます。それ以外は全体で共有します。

| | ターゲットごと |
| :--- | :--- |
| HDMI キャプチャ | 可 |
| CH9329 のキーボードとマウス | 可 |
| ATX 電源制御 | 不可。GPIO ピンは1組で、そこに配線した1台だけを制御します |
| OTG マスストレージ | 不可。USB デバイスポートは1つで、そこに接続した1台だけに見えます |

複数のマシンの電源を制御したい場合は、内蔵の ATX ウィジェットではなく、別のピンに割り当てた user GPIO のボタンを使うといいです。[GPIO にボタンを追加する](#gpio-にボタンを追加する)を参照してください。

## ATX 電源制御

kvmd は、Pi の GPIO ピン経由でターゲットの電源スイッチとリセットスイッチを押し、電源 LED を読み取れます。配線については PiKVM の [ATX ドキュメント](https://docs.pikvm.org/atx_board/)を参照してください。

GPIO チップのデバイスメジャー番号は環境によって異なり、カーネルを更新すると変わることがあります。そのため、番号を調べて書き込む必要があります。

### 1. メジャー番号と、チップの所有グループを調べる

```sh
$ ls -la /dev/gpiochip0
crw-rw---- 1 root gpio 254, 0 Sep  1 12:00 /dev/gpiochip0
#                 ^^^^ ^^^
#                 |    メジャー番号
#                 所有グループ
```

チップの所有グループが `root` であってはなりません。`root` になっている場合は、そのチップ専用のグループをホスト側で用意してください。

```sh
sudo groupadd pikvm-gpio
echo 'SUBSYSTEM=="gpio", KERNEL=="gpiochip0", GROUP:="pikvm-gpio", MODE:="0660"' \
  | sudo tee /etc/udev/rules.d/10-pikvm-gpiochip.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=gpio
```

慣例的な `gpio` ではなく専用の名前を付けてください。Raspberry Pi 向けのイメージは、ボードのもう一方の GPIO チップ、`/dev/gpiomem`、sysfs の GPIO および PWM ツリーまで `gpio` グループへ渡すルールを同梱しており、その名前のグループが存在した時点でこれらが有効になります。

グループの作成は、ルールを書く前に行ってください。udev は、解決できないグループ名を書いたルールを破棄します。

### 2. `compose.yml` にメジャー番号を追加する

```yaml
    device_cgroup_rules:
      - 'c 81:* rmw'
      - 'c 166:* rmw'
      - 'c 188:* rmw'
      - 'c 254:* rmw'   # gpiochip — カーネル更新のたびに確認する
```

### 3. `config/override.yaml` で ATX を有効にする

コンテナからはホストの `/dev` が `/hostdev` として見えるため、チップはそちらのパスで指定してください。

```yaml
kvmd:
    atx:
        type: gpio
        device: /hostdev/gpiochip0
```

ピン番号は PiKVM の標準配線が既定値になります。電源スイッチが BCM 23、リセットスイッチが BCM 27、電源 LED が BCM 24、HDD LED が BCM 22 です。配線が異なる場合は、`power_switch_pin`、`reset_switch_pin`、`power_led_pin`、`hdd_led_pin` を同じファイルに追加してください。

### 4. 反映する

`compose.yml` を変更しているため、再起動では足りません。

```sh
docker compose up -d
```

カーネルを更新したら、手順 1 と 2 をやり直してください。（変更される場合があるため）

## GPIO にボタンを追加する

kvmd の user GPIO は、任意の機能を持つボタンを Web UI に並べる仕組みです。wake パケットの送信、リレーの駆動、コマンドの実行などが行えます。ターゲット切り替えのボタンも同じビュー上にあり、そこへ独自のボタンを並べられます。利用できるドライバの一覧は PiKVM の [GPIO ドキュメント](https://docs.pikvm.org/gpio/)にあります。

### 1. `config/override.yaml` でチャンネルを定義する

チャンネルは、[ドライバ](https://docs.pikvm.org/gpio/#drivers)と、それを指す [scheme](https://docs.pikvm.org/gpio/#scheme) のエントリの組で定義します。次の例は [Wake-on-LAN](https://docs.pikvm.org/gpio/#wake-on-lan) を送信するチャンネルです。

```yaml
kvmd:
    gpio:
        drivers:
            wol_workstation:
                type: wol
                mac: ff:ff:ff:ff:ff:f1
        scheme:
            b_wol:
                driver: wol_workstation
                pin: 0
                mode: output
                switch: false
```

### 2. 同じファイルでビューに並べる

[ビュー](https://docs.pikvm.org/gpio/#view)の1行はセルのリストです。`#文字列` は見出しを、`チャンネル|文字列` はボタンを表します。ターゲットのボタンは、独立した区画としてこれらの行の上に置かれます。

```yaml
kvmd:
    gpio:
        view:
            table:
                - ["#電源"]
                - ["b_wol|ワークステーションを起動"]
```

### 3. 反映する

```sh
docker compose restart
```

## OTG モード

OTG モードでは、Web UI からディスクイメージをアップロードして、USB ドライブとしてマシンに見せられます。OS のインストーラーを渡す用途などに使えます。これは kvmd の[マスストレージドライブ](https://docs.pikvm.org/msd/)機能に当たり、コンテナが特権で動く唯一のモードです。

OTG が有効な間も、キーボード、マウス、映像は通常どおり動作します。ただし、このドライブは選択中のターゲットとは連動しません。Pi の USB デバイスポートに接続したマシンにだけ見え、そのポートは Pi に1つしかありません。

### 有効にする

```sh
docker compose -f compose.yml -f compose.otg.yml up -d
```

イメージのアップロードとマウントは、Web UI の Drive メニューから行います。

### 無効に戻す

```sh
docker compose up -d
```

## ログ

起動時の処理とターゲットの切り替えは `docker logs` に出ます。

```sh
docker compose logs -f
```

kvmd 自身の出力はコンテナの journal に入ります。この内容は、コンテナを作り直すと失われます。

```sh
docker compose exec pikvm journalctl -u kvmd.service -f
```

## コントリビュート

Issue と Pull Request を歓迎します。

## ライセンス

[MIT](LICENSE)
