# WevoSpace Propose API ドキュメント

> English version: [PROPOSE_API.md](PROPOSE_API.md)

## 概要

Proposeは、多者間の合意を暗号署名で記録・管理する仕組みです。1人の作成者（creator）と1人以上の相手方（counterparty）が関与し、署名によって状態遷移が担保されます。認証機構は設けず、すべての操作は署名検証によってセキュリティを確保します。

**ベースURL**:
- 開発環境: `http://localhost:8080/v1`
- 本番環境: `https://api.wevospace.example.com/v1`

---

## データモデル

### ProposeResponse

| フィールド | 型 | 説明 |
|---|---|---|
| `id` | UUID | Propose ID（クライアントが生成） |
| `contentHash` | string | コンテンツのハッシュ値 |
| `creatorPublicKey` | string | 作成者の公開鍵（JWK JSON文字列） |
| `creatorSignature` | string | 作成者の署名（Base64 / DER） |
| `counterparties` | CounterpartyInfo[] | 相手方と各署名のリスト |
| `honorCreatorSignature` | string? | 作成者のhonor署名 |
| `honorCreatorTimestamp` | string? | 作成者のhonorタイムスタンプ（ISO8601） |
| `partCreatorSignature` | string? | 作成者のpart署名 |
| `partCreatorTimestamp` | string? | 作成者のpartタイムスタンプ（ISO8601） |
| `dissolvedAt` | string? | 解消タイムスタンプ（ISO8601） |
| `status` | string | 状態（下記参照） |
| `signatureVersion` | integer | 署名スキームバージョン（現行: 1） |
| `createdAt` | string | 作成日時（ISO8601、クライアントが生成） |
| `updatedAt` | string? | 最終更新日時（サーバーが管理） |

### CounterpartyInfo

| フィールド | 型 | 説明 |
|---|---|---|
| `publicKey` | string | 相手方の公開鍵（JWK JSON文字列） |
| `signSignature` | string? | `/sign` の署名（署名後にセット） |
| `signTimestamp` | string? | `/sign` のタイムスタンプ（ISO8601） |
| `honorSignature` | string? | `/honor` の署名 |
| `honorTimestamp` | string? | `/honor` のタイムスタンプ（ISO8601） |
| `partSignature` | string? | `/part` の署名 |
| `partTimestamp` | string? | `/part` のタイムスタンプ（ISO8601） |

### 状態一覧

| status | 意味 |
|---|---|
| `proposed` | 作成者が提案済み、全相手方の署名待ち |
| `signed` | 全相手方が署名済み、合意成立 |
| `honored` | 作成者＋全相手方がhonor署名済み |
| `dissolved` | 解消済み（proposed状態から） |
| `parted` | いずれかの参加者がpart署名を送信した時点で即座に遷移 |

### 状態遷移図

```
proposed ──sign（全相手方）──→ signed ──honor（全員）──→ honored
    │                             │
  dissolve                     part（いずれか1人→即座に遷移）
    │                             │
    ↓                             ↓
dissolved                      parted
```

---

## 署名の仕様

- 鍵アルゴリズム: **P-256 ECDSA**
- 公開鍵形式: **JWK（JSON Web Key）** — `crv`、`kty`、`x`、`y` フィールドを含むJSON文字列（x・y は Base64URL エンコードされた32バイトの座標値）
- 署名形式: Base64エンコードされた **DER形式**

**公開鍵の例:**
```json
{"crv":"P-256","kty":"EC","x":"IrH3k5a8Q2mXvP1nQ7rAbCdEfGhIjKlMnOpQrSt","y":"UvWxYzAaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPp"}
```

### 署名対象の文字列

各操作で署名する文字列は以下の通りです。フィールドは連結のみ（区切り文字なし）。

| 操作 | 署名対象文字列 |
|---|---|
| Propose作成 | `"proposed." + proposeId + contentHash + creatorPublicKey + counterpartyPublicKeys（ソート&結合） + createdAt` |
| sign | `"signed." + proposeId + contentHash + signerPublicKey + timestamp` |
| dissolved | `"dissolved." + proposeId + contentHash + publicKey + timestamp` |
| honored | `"honored." + proposeId + contentHash + publicKey + timestamp` |
| parted | `"parted." + proposeId + contentHash + publicKey + timestamp` |

> **注意**: `proposeId` は大文字のUUID文字列（例: `550E8400-E29B-41D4-A716-446655440000`）を使用してください。
>
> **作成時**: `counterpartyPublicKeys` を辞書順でソートして連結（区切り文字なし）したものを使用します。

---

## エンドポイント一覧

| メソッド | パス | 説明 |
|---|---|---|
| `POST` | `/proposes` | Propose作成 |
| `GET` | `/proposes/:id` | Propose詳細取得 |
| `PATCH` | `/proposes/:id/sign` | 相手方が署名（全員揃うと `signed` に自動遷移） |
| `DELETE` | `/proposes/:id` | 解消（proposed → dissolved） |
| `PATCH` | `/proposes/:id/honor` | honor署名を追加（全員揃うと `honored` に自動遷移） |
| `PATCH` | `/proposes/:id/part` | part署名を追加（いずれか1人が送れば即座に `parted` へ遷移） |
| `GET` | `/health` | ヘルスチェック |
| `GET` | `/info` | サーバー情報・ピアノード一覧 |
| `GET` | `/v1/sync/proposes` | 指定日時以降に更新されたProposeを取得（ノード間同期） |
| `POST` | `/v1/sync/proposes/batch` | Proposeのバッチをマージ（ノード間同期） |

---

## 1. POST /proposes — Propose作成

作成者が新しいProposeを作成します。`"proposed." + proposeId + contentHash + creatorPublicKey + counterpartyPublicKeys（ソート&結合） + createdAt` に署名します。

### リクエストボディ

```json
{
  "proposeId": "550E8400-E29B-41D4-A716-446655440000",
  "contentHash": "abc123def456",
  "creatorPublicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
  "creatorSignature": "MEUC...",
  "counterpartyPublicKeys": [
    "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"AbCd...\",\"y\":\"EfGh...\"}",
    "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IjKl...\",\"y\":\"MnOp...\"}"
  ],
  "createdAt": "2026-01-01T00:00:00Z"
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `proposeId` | string | ✅ | UUID文字列（クライアントが生成） |
| `contentHash` | string | ✅ | コンテンツのハッシュ値 |
| `creatorPublicKey` | string | ✅ | 作成者の公開鍵 |
| `creatorSignature` | string | ✅ | 作成者の署名 |
| `counterpartyPublicKeys` | string[] | ✅ | 相手方の公開鍵（1件以上） |
| `createdAt` | string | ✅ | ISO8601形式の作成日時 |

### レスポンス

| ステータス | 説明 |
|---|---|
| 201 Created | 作成成功 |
| 400 | `proposeId` の形式が無効、または `counterpartyPublicKeys` が空 |
| 401 | 署名検証失敗 |
| 409 Conflict | 同じIDのProposeが既に存在 |

---

## 2. GET /proposes/:id — Propose詳細取得

### リクエスト例

```
GET /v1/proposes/550E8400-E29B-41D4-A716-446655440000
```

### レスポンス (200 OK)

`ProposeResponse` オブジェクト（上記データモデル参照）

### エラー

| ステータス | 理由 |
|---|---|
| 400 | 無効なUUID形式 |
| 404 | Proposeが見つからない |

---

## 3. PATCH /proposes/:id/sign — 相手方署名（proposed → 全員署名でsigned）

相手方が `"signed." + proposeId + contentHash + signerPublicKey + timestamp` に署名します。
**全ての** 相手方が署名した時点で `signed` 状態に自動遷移します。

### リクエストボディ

```json
{
  "signerPublicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"AbCd...\",\"y\":\"EfGh...\"}",
  "signature": "MEUC...",
  "timestamp": "2026-01-01T00:00:00Z"
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `signerPublicKey` | string | ✅ | 署名者の公開鍵（登録済みの相手方であること） |
| `signature` | string | ✅ | 署名者の署名 |
| `timestamp` | string | ✅ | 操作タイムスタンプ（ISO8601） |

### レスポンス

| ステータス | 説明 |
|---|---|
| 200 OK | 署名成功。全相手方が揃えば `signed` 状態に遷移 |
| 400 | 無効なPropose ID |
| 401 | 署名検証失敗 |
| 403 Forbidden | `signerPublicKey` が登録済み相手方ではない |
| 404 | Proposeが見つからない |
| 409 Conflict | `proposed` 状態ではない |

---

## 4. DELETE /proposes/:id — 解消（proposed → dissolved）

作成者またはいずれかの相手方が `"dissolved." + proposeId + contentHash + publicKey + timestamp` に署名して解消します。`proposed` 状態のみ可。

### リクエストボディ

```json
{
  "publicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
  "signature": "MEUC...",
  "timestamp": "2026-01-02T00:00:00Z"
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `publicKey` | string | ✅ | 操作者の公開鍵（creator or counterparty） |
| `signature` | string | ✅ | 操作者の署名 |
| `timestamp` | string | ✅ | 操作時刻（ISO8601） |

### レスポンス

| ステータス | 説明 |
|---|---|
| 200 OK | 解消成功、`dissolved` 状態に遷移 |
| 401 | 署名検証失敗 |
| 403 Forbidden | 参加者以外の公開鍵 |
| 404 | Proposeが見つからない |
| 409 Conflict | `proposed` 状態ではない |

---

## 5. PATCH /proposes/:id/honor — Honor署名（signed → 全員で honored）

`"honored." + proposeId + contentHash + publicKey + timestamp` に署名します。作成者と**全ての**相手方が揃った時点で `honored` 状態に自動遷移します。

### リクエストボディ

```json
{
  "publicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
  "signature": "MEUC...",
  "timestamp": "2026-01-03T00:00:00Z"
}
```

### レスポンス

| ステータス | 説明 |
|---|---|
| 200 OK | 署名記録。全員揃えば `honored` に遷移 |
| 401 | 署名検証失敗 |
| 403 Forbidden | 参加者以外の公開鍵 |
| 404 | Proposeが見つからない |
| 409 Conflict | `signed` 状態ではない |

---

## 6. PATCH /proposes/:id/part — Part署名（signed → いずれか1人で即座にparted）

`"parted." + proposeId + contentHash + publicKey + timestamp` に署名します。**いずれかの参加者が送った時点で即座に** `parted` 状態に遷移します。全員分を待ちません。

### リクエストボディ

```json
{
  "publicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
  "signature": "MEUC...",
  "timestamp": "2026-01-03T00:00:00Z"
}
```

### レスポンス

| ステータス | 説明 |
|---|---|
| 200 OK | 署名記録。即座に `parted` へ遷移 |
| 401 | 署名検証失敗 |
| 403 Forbidden | 参加者以外の公開鍵 |
| 404 | Proposeが見つからない |
| 409 Conflict | `signed` 状態ではない |

---

## ユーティリティエンドポイント

### GET /health — ヘルスチェック

サーバーの稼働状態を返します。バージョンプレフィックスなし（`/v1` 不要）。

```
GET /health
```

**レスポンス (200 OK)**

```json
{
  "status": "ok",
  "timestamp": "1711234567.0"
}
```

---

### GET /info — サーバー情報

プロトコル名、サーバーバージョン、クラスター内のピアノードURLを返します。バージョンプレフィックスなし（`/v1` 不要）。

```
GET /info
```

**レスポンス (200 OK)**

```json
{
  "protocol": "wevo",
  "version": "0.2.0",
  "peers": ["https://node-b.example.com", "https://node-c.example.com"]
}
```

シングルノード構成の場合、`peers` は空配列になります。

---

## ノード間同期エンドポイント

これらのエンドポイントはマルチノード構成においてノード間の同期専用です。エンドユーザークライアントからの呼び出しは想定していません。

認証: `Authorization: Bearer <SYNC_SECRET>`（サーバーに `SYNC_SECRET` が設定されている場合は必須）

### GET /v1/sync/proposes — 更新済みProposeを取得

指定タイムスタンプ以降に更新されたProposeをすべて返します。ピアノードが差分を取得するために使用します。

**クエリパラメータ**

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `after` | string | ✅ | ISO8601タイムスタンプ。この日時より後に更新されたProposeを返す |

**リクエスト例**

```
GET /v1/sync/proposes?after=2026-01-01T00:00:00Z
Authorization: Bearer <SYNC_SECRET>
```

**レスポンス (200 OK)**

```json
[
  { /* ProposeResponseオブジェクト */ },
  { /* ProposeResponseオブジェクト */ }
]
```

| ステータス | 説明 |
|---|---|
| 200 OK | ProposeResponseの配列（空配列も可） |
| 400 | `after` パラメータが不正または欠落 |
| 401 | `Authorization` ヘッダーが不正または欠落（`SYNC_SECRET` 設定時） |

---

### POST /v1/sync/proposes/batch — Proposeバッチをプッシュ

Proposeの配列を受け取り、ローカルDBにマージします。各Proposeはupsert方式で処理されます。既存フィールドをnullで上書きすることはなく、署名フィールドはnullの場合にのみ書き込みます（append-onlyマージ）。

**リクエストボディ**

```json
[
  { /* ProposeResponseオブジェクト */ },
  { /* ProposeResponseオブジェクト */ }
]
```

**レスポンス**

| ステータス | 説明 |
|---|---|
| 200 OK | バッチを受理してマージ完了 |
| 400 | リクエストボディが不正 |
| 401 | `Authorization` ヘッダーが不正または欠落（`SYNC_SECRET` 設定時） |

---

## レート制限

全エンドポイントにレート制限が適用されます。

| ヘッダー | 説明 |
|---|---|
| `X-RateLimit-Limit` | 上限リクエスト数（60/分） |
| `X-RateLimit-Remaining` | 残りリクエスト数 |
| `X-RateLimit-Reset` | リセット時刻（UNIXタイムスタンプ） |
| `Retry-After` | 制限超過時：次にリトライ可能になるまでの秒数 |

制限超過時のレスポンス: **429 Too Many Requests**

---

## cURL 使用例

### Propose作成（相手方2名）

```bash
CREATOR_JWK='{"crv":"P-256","kty":"EC","x":"IrH3...","y":"UvWx..."}'
COUNTERPARTY1_JWK='{"crv":"P-256","kty":"EC","x":"AbCd...","y":"EfGh..."}'
COUNTERPARTY2_JWK='{"crv":"P-256","kty":"EC","x":"IjKl...","y":"MnOp..."}'

curl -X POST http://localhost:8080/v1/proposes \
  -H "Content-Type: application/json" \
  -d "{
    \"proposeId\": \"550E8400-E29B-41D4-A716-446655440000\",
    \"contentHash\": \"abc123def456\",
    \"creatorPublicKey\": $CREATOR_JWK,
    \"creatorSignature\": \"MEUC...\",
    \"counterpartyPublicKeys\": [$COUNTERPARTY1_JWK, $COUNTERPARTY2_JWK],
    \"createdAt\": \"2026-01-01T00:00:00Z\"
  }"
```

### 相手方署名（sign）

```bash
COUNTERPARTY_JWK='{"crv":"P-256","kty":"EC","x":"AbCd...","y":"EfGh..."}'

curl -X PATCH http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000/sign \
  -H "Content-Type: application/json" \
  -d "{
    \"signerPublicKey\": $COUNTERPARTY_JWK,
    \"signature\": \"MEUC...\",
    \"timestamp\": \"2026-01-01T00:00:00Z\"
  }"
```

### 解消（dissolve）

```bash
CREATOR_JWK='{"crv":"P-256","kty":"EC","x":"IrH3...","y":"UvWx..."}'

curl -X DELETE http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000 \
  -H "Content-Type: application/json" \
  -d "{
    \"publicKey\": $CREATOR_JWK,
    \"signature\": \"MEUC...\",
    \"timestamp\": \"2026-01-02T00:00:00Z\"
  }"
```

### Honor署名

```bash
CREATOR_JWK='{"crv":"P-256","kty":"EC","x":"IrH3...","y":"UvWx..."}'

curl -X PATCH http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000/honor \
  -H "Content-Type: application/json" \
  -d "{
    \"publicKey\": $CREATOR_JWK,
    \"signature\": \"MEUC...\",
    \"timestamp\": \"2026-01-03T00:00:00Z\"
  }"
```

---

## バージョン

API Version: 1.0.0（WevoSpace サーバーバージョン: 0.2.0）
最終更新: 2026-04-05
