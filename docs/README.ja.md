# v-nico-list

niconico のユーザーページ・マイリストから動画 ID を取得する V 製 CLI です。[go-nico-list](https://github.com/sh4869221b/go-nico-list/tree/6638228b9acfa6256805f5e57bdd75f4ca80e084) の現行オプションと出力形式を移植しています。

Linux ではループバック統合テスト 55 件に合格しました。Windows ネイティブ CI は 49 件に合格し、POSIX シグナル専用の 6 件を除外しています。公開済みベースラインの合成ベンチマークは Go 参照実装より遅い結果でした。最新の [JSON・ソート最適化](PERFORMANCE.md) はその V ベースラインより所要時間を短縮していますが、Go との再比較ではありません。実測値と検証範囲は [VALIDATION.md](VALIDATION.md) を参照してください。

[English](../README.md) · [互換性・通信の制限](COMPATIBILITY.md) · [検証・ベンチマーク](VALIDATION.md)

## ビルド

公式 V コンパイラの固定リビジョンは `scripts/v-revision`、ブートストラップ用ソースは `scripts/vc-revision` に記録しています。Linux では C コンパイラ、OpenSSL と Boehm GC の開発ライブラリが必要です。Debian/Ubuntu の例は `gcc make libssl-dev libgc-dev openssl` です。

```sh
V=/path/to/v/v scripts/build.sh
./bin/v-nico-list --help
```

curl コマンドや libcurl は使用しません。Linux は V の OpenSSL バックエンドを使用します。Windows は MSVC と V 標準の Mbed TLS バックエンドでビルド・実行し、[両 OS のネイティブ CI](https://github.com/sh4869221b/v-nico-list/actions/runs/42152349163) が成功しました。ビルド済みリリースはまだありません。

## 使用例

```sh
v-nico-list nicovideo.jp/user/12345
v-nico-list https://www.nicovideo.jp/user/12345/video --url
v-nico-list nicovideo.jp/user/1 nicovideo.jp/mylist/847130 -T8 -P4 -H8
v-nico-list --input-file targets.txt --json --dedupe
cat targets.txt | v-nico-list --stdin
```

位置引数、入力ファイル、標準入力の順に読み取ります。ファイル・標準入力の空行は無視し、前後の空白を除去します。1 行の上限は 1 MiB です。互換性のため URL は部分一致で抽出します。同じ入力にユーザー URL とマイリスト URL がある場合はユーザーを優先します。ユーザー ID は最大 9 桁、マイリスト ID は最大 12 桁で一致し、より長い数値もその桁数で切り出します。

通常は動画 ID を数値順で 1 行ずつ標準出力へ書き出します。`--url` で視聴 URL、`--dedupe` で重複除去、`--no-sort` で並べ替えを省略します。`--no-sort` の行出力は完了した対象から出力するため対象間の順序は不定です。JSON と併用した場合は全体の `items` を入力順にします。ログ・進捗・集計は標準エラーへ出力し、`--logfile` 指定時は構造化ログだけをファイルへ追記します。

## オプション

| オプション | 既定値 | 内容 |
| --- | --- | --- |
| `-c, --comment` | `0` | この値を超えるコメント数の動画だけを含める |
| `-a, --dateafter` | `10000101` | 最初に含める UTC 日付 (`YYYYMMDD`) |
| `-b, --datebefore` | `99991231` | 最後に含める UTC 日付 (`YYYYMMDD`) |
| `-u, --url` | `false` | 行出力を視聴 URL にする |
| `-T, --concurrency-targets` | `3` | 同時取得対象数（1 以上） |
| `-P, --concurrency-pages` | `1` | 対象ごとの同時取得ページ数（1 以上） |
| `-H, --concurrency-http` | `0` | コマンド全体の HTTP 同時実行上限（0 で追加制限なし） |
| `-A, --concurrency-adaptive` | `false` | 未指定の同時実行レイヤーを自動調整 |
| `--http-metrics` | `false` | HTTP 集計メトリクスをログ出力 |
| `--rate-limit` | `0` | 全体の毎秒リクエスト上限（0 で無効） |
| `--min-interval` | `0s` | リクエスト間の最小時間 |
| `--timeout` | `10s` | HTTP 試行ごとのタイムアウト |
| `--retries` | `10` | リクエストごとの総試行回数（1 以上） |
| `--input-file` | 空 | 改行区切りの入力ファイル |
| `--stdin` | `false` | 標準入力も読み込む |
| `--logfile` | 空 | 構造化ログの追記先 |
| `--progress` | `false` | 進捗表示を強制 |
| `--no-progress` | `false` | 進捗表示を無効化（強制指定にも優先） |
| `--strict` | `false` | 無効な入力があれば失敗 |
| `--best-effort` | `false` | 取得失敗の終了コードを抑制 |
| `--dedupe` | `false` | 全体の出力 ID を重複除去 |
| `--no-sort` | `false` | 全体の並べ替えを省略 |
| `--json` | `false` | JSON オブジェクトを出力 |
| `-h, --help` | | ヘルプ表示 |
| `-v, --version` | | バージョン表示 |

日付の両端は UTC 基準で含めます。動画のタイムスタンプに時差があっても、UTC に換算して判定します。コメント数の下限は含めません。

同じオプションを繰り返した場合、長形式・短形式を混在させても最後の値を使います。`-A -T3` は対象数だけを固定し、ページ数・HTTP 上限を自動調整します。既定値と同じ値の明示指定も固定扱いです。`-A -H0` は HTTP の追加上限を明示的に無効化します。`-T3` のような値の結合、`-uA` のような真偽値の結合、`--strict=false` に対応します。旧名 `--concurrency`、`--page-concurrency`、`--http-concurrency`、`--adaptive-concurrency`, `--adaptive-http-concurrency`, `--tab`, `-t`, `--max-pages`, `--max-videos`、`-n` はエラーです。

## JSON・終了コード

JSON のトップレベルは `inputs`、`invalid`、`targets`、`errors`、`output_count`、`items` です。配列は空でも `[]` になります。`targets` は種類と数値 ID 順で、各対象は `type`、`id`、`items`、`error` を持ちます。対象別 `items` はページ順を保ち、並べ替え・重複除去は全体の `items` だけに適用します。JSON では `--url` を指定しても ID のままです。

取得エラーがなければ終了コード 0 です。既定では無効入力をスキップします。`--strict` は無効入力を失敗扱いにし、`--best-effort` より優先します。設定・入力ファイル・出力のエラーは `--best-effort` でも失敗です。取得に失敗しても、ほかの対象や失敗前の連続したページの結果を出力します。キャンセル・リクエスト期限切れは参照実装に合わせ、対象を空の成功結果にします。

最初に 1 ページ目を取得します。総件数不明の場合、空ページまたは 404 まで順次取得します。固定 `-P1` も総件数にかかわらず同じ動作です。ページ並列実行では、既知の総件数で範囲を制限し、最初の空ページ・失敗ページより前の結果だけを採用します。再試行の待機中は HTTP 枠を解放します。全対象・全ページ・再試行でペーシングを共有し、100 ms から最大 30 秒の指数バックオフと 429 の `Retry-After` に従います。自動調整時の 429 待機はコマンド全体に適用します。

## 開発・検証

```sh
/path/to/v/v -cc gcc -d use_openssl test src
python3 tests/integration.py --binary bin/v-nico-list
python3 scripts/benchmark.py --binary v=bin/v-nico-list --output /tmp/v-benchmark.json
```

統合テストは合成 HTTP/HTTPS ループバックサーバーだけを使います。TLS 証明書生成に OpenSSL コマンドが必要です。CLI・日時・ページ分割・部分結果・再試行・同時実行・ペーシング・キャンセル・TLS 検証・gzip・chunked 応答・展開後 8 MiB 上限を検証します。ローカル合成測定を実サービスの性能と解釈しないでください。実行済みの検証結果は [VALIDATION.md](VALIDATION.md) を参照してください。

開発用の `NICO_BASE_URL` で API 基底 URL（既定 `https://nvapi.nicovideo.jp/v3`）を変更できます。テストでは末尾が `/v3` のループバック URL を指定します。TLS 検証やプロキシ設定は引き続き適用されます。
