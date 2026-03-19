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
| `partCreatorSignature` | string? | 作成者のpart署名 |
| `status` | string | 状態（下記参照） |
| `createdAt` | string | 作成日時（ISO8601、クライアントが生成） |
| `updatedAt` | string? | 最終更新日時（サーバーが管理） |

### CounterpartyInfo

| フィールド | 型 | 説明 |
|---|---|---|
| `publicKey` | string | 相手方の公開鍵（JWK JSON文字列） |
| `signSignature` | string? | `/sign` の署名（署名後にセット） |
| `honorSignature` | string? | `/honor` の署名 |
| `partSignature` | string? | `/part` の署名 |

### 状態一覧

| status | 意味 |
|---|---|
| `proposed` | 作成者が提案済み、全相手方の署名待ち |
| `signed` | 全相手方が署名済み、合意成立 |
| `honored` | 作成者＋全相手方がhonor署名済み |
| `dissolved` | 解消済み（proposed状態から） |
| `parted` | 作成者＋全相手方がpart署名済み |

### 状態遷移図

```
proposed ──sign（全相手方）──→ signed ──honor（全員）──→ honored
    │                             │
  dissolve                     part（全員）
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

> **GETリクエスト時の注意**: 公開鍵をURLクエリパラメータとして渡す場合は、JWK文字列全体をパーセントエンコードしてください（例: `encodeURIComponent` を使用）。


### 署名対象の文字列

各操作で署名する文字列は以下の通りです。フィールドは連結のみ（区切り文字なし）。

| 操作 | 署名対象文字列 |
|---|---|
| Propose作成 | `proposeId + contentHash + counterpartyPublicKeys（ソート&結合） + createdAt` |
| sign | `proposeId + contentHash + signerPublicKey + createdAt` |
| dissolved | `"dissolved." + proposeId + contentHash + timestamp` |
| honored | `"honored." + proposeId + contentHash + timestamp` |
| parted | `"parted." + proposeId + contentHash + timestamp` |

> **注意**: `proposeId` は大文字のUUID文字列（例: `550E8400-E29B-41D4-A716-446655440000`）を使用してください。
>
> **作成時**: `counterpartyPublicKeys` を辞書順でソートして連結（区切り文字なし）したものを使用します。

---

## エンドポイント一覧

| メソッド | パス | 説明 |
|---|---|---|
| `GET` | `/proposes` | Propose一覧取得 |
| `POST` | `/proposes` | Propose作成 |
| `GET` | `/proposes/:id` | Propose詳細取得 |
| `PATCH` | `/proposes/:id/sign` | 相手方が署名（全員揃うと `signed` に自動遷移） |
| `DELETE` | `/proposes/:id` | 解消（proposed → dissolved） |
| `PATCH` | `/proposes/:id/honor` | honor署名を追加（全員揃うと `honored` に自動遷移） |
| `PATCH` | `/proposes/:id/part` | part署名を追加（全員揃うと `parted` に自動遷移） |

---

## 1. GET /proposes — Propose一覧取得

指定した公開鍵が creator または いずれかの counterparty であるProposeを返します。

### クエリパラメータ

| パラメータ | 必須 | 説明 |
|---|---|---|
| `publicKey` | ✅ | 検索する公開鍵（JWK、パーセントエンコード済み） |
| `status` | ✗ | 絞り込むステータス（カンマ区切りで複数指定可） |
| `page` | ✗ | ページ番号（デフォルト: 1） |
| `per` | ✗ | 1ページあたりの件数（デフォルト: 10） |

### リクエスト例

```
GET /v1/proposes?publicKey=%7B%22crv%22%3A%22P-256%22%2C%22kty%22%3A%22EC%22%2C%22x%22%3A%22IrH3...%22%2C%22y%22%3A%22UvWx...%22%7D&status=proposed,signed
```

### レスポンス (200 OK)

```json
{
  "items": [
    {
      "id": "550E8400-E29B-41D4-A716-446655440000",
      "contentHash": "abc123def456",
      "creatorPublicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
      "creatorSignature": "MEUC...",
      "counterparties": [
        {
          "publicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"AbCd...\",\"y\":\"EfGh...\"}",
          "signSignature": null,
          "honorSignature": null,
          "partSignature": null
        }
      ],
      "honorCreatorSignature": null,
      "partCreatorSignature": null,
      "status": "proposed",
      "createdAt": "2026-01-01T00:00:00Z",
      "updatedAt": "2026-01-01T00:00:00Z"
    }
  ],
  "metadata": {
    "page": 1,
    "per": 10,
    "total": 1
  }
}
```

### エラー

| ステータス | 理由 |
|---|---|
| 400 | `publicKey` が未指定 |

---

## 2. POST /proposes — Propose作成

作成者が新しいProposeを作成します。`proposeId + contentHash + counterpartyPublicKeys（ソート&結合） + createdAt` に署名します。

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

## 3. GET /proposes/:id — Propose詳細取得

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

## 4. PATCH /proposes/:id/sign — 相手方署名（proposed → 全員署名でsigned）

相手方が `proposeId + contentHash + signerPublicKey + createdAt` に署名します。
**全ての** 相手方が署名した時点で `signed` 状態に自動遷移します。

### リクエストボディ

```json
{
  "signerPublicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"AbCd...\",\"y\":\"EfGh...\"}",
  "signature": "MEUC...",
  "createdAt": "2026-01-01T00:00:00Z"
}
```

| フィールド | 型 | 必須 | 説明 |
|---|---|---|---|
| `signerPublicKey` | string | ✅ | 署名者の公開鍵（登録済みの相手方であること） |
| `signature` | string | ✅ | 署名者の署名 |
| `createdAt` | string | ✅ | Proposeの `createdAt`（一致確認用） |

### レスポンス

| ステータス | 説明 |
|---|---|
| 200 OK | 署名成功。全相手方が揃えば `signed` 状態に遷移 |
| 400 | `createdAt` が不一致、または無効なUUID |
| 401 | 署名検証失敗 |
| 403 Forbidden | `signerPublicKey` が登録済み相手方ではない |
| 404 | Proposeが見つからない |
| 409 Conflict | `proposed` 状態ではない |

---

## 5. DELETE /proposes/:id — 解消（proposed → dissolved）

作成者またはいずれかの相手方が `"dissolved." + proposeId + contentHash + timestamp` に署名して解消します。`proposed` 状態のみ可。

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

## 6. PATCH /proposes/:id/honor — Honor署名（signed → 全員で honored）

`"honored." + proposeId + contentHash + timestamp` に署名します。作成者と**全ての**相手方が揃った時点で `honored` 状態に自動遷移します。

### リクエストボディ

```json
{
  "publicKey": "BHqG...",
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

## 7. PATCH /proposes/:id/part — Part署名（signed → 全員で parted）

`"parted." + proposeId + contentHash + timestamp` に署名します。作成者と**全ての**相手方が揃った時点で `parted` 状態に自動遷移します。

### リクエストボディ

```json
{
  "publicKey": "BHqG...",
  "signature": "MEUC...",
  "timestamp": "2026-01-03T00:00:00Z"
}
```

### レスポンス

| ステータス | 説明 |
|---|---|
| 200 OK | 署名記録。全員揃えば `parted` に遷移 |
| 401 | 署名検証失敗 |
| 403 Forbidden | 参加者以外の公開鍵 |
| 404 | Proposeが見つからない |
| 409 Conflict | `signed` 状態ではない |

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
    \"createdAt\": \"2026-01-01T00:00:00Z\"
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

API Version: 1.0.0
最終更新: 2026-03-19
