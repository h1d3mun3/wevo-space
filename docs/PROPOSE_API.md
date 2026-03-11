# WevoSpace Propose API ドキュメント

## 概要

Proposeは、複数の暗号署名によって承認されたメッセージです。このAPIでは、Proposeの作成と署名の追加管理ができます。

**認証**: 現在、認証機構はありません。本番環境での使用前にセキュリティを実装してください。

---

## ベースURL

- **開発環境**: `http://localhost:8080`
- **本番環境**: `https://api.wevoSpace.example.com`

---

## エンドポイント一覧

| メソッド | パス | 説明 |
|---------|------|------|
| POST | `/proposes` | 新しいProposeを作成 |
| PUT | `/proposes/{id}` | 既存のProposeに署名を追加 |

---

## 1. Proposeを作成

### リクエスト

```
POST /proposes
Content-Type: application/json
```

#### リクエストボディ

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "payloadHash": "abc123def456",
  "signatures": [
    {
      "publicKey": "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0K...",
      "signature": "MEUCIQD1234567890..."
    }
  ]
}
```

#### パラメータ

| 項目 | 型 | 必須 | 説明 | 制限 |
|------|-----|------|------|------|
| `id` | UUID | ✅ | Propose ID（クライアント生成） | - |
| `payloadHash` | string | ✅ | ペイロードのハッシュ値（SHA256など） | 最大256文字 |
| `signatures` | array | ✅ | 署名の配列 | 1〜1000個 |
| `signatures[].publicKey` | string | ✅ | Base64エンコードされた公開鍵（P256 X.963形式） | 最大500文字 |
| `signatures[].signature` | string | ✅ | Base64エンコードされたDER形式の署名 | 最大500文字 |

### レスポンス

#### 成功時 (201 Created)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "payloadHash": "abc123def456",
  "createdAt": "2026-03-11T10:30:00Z"
}
```

#### エラー時

##### 400 Bad Request - 入力値の検証エラー

```json
{
  "error": "payloadHash must be 256 characters or less"
}
```

**発生する可能性のあるエラー:**
- `payloadHash must be 256 characters or less` - payloadHashが256文字を超えている
- `signatures must be 1000 or fewer` - signatures配列が1000個を超えている
- `publicKey must be 500 characters or less` - publicKeyが500文字を超えている
- `signature must be 500 characters or less` - signatureが500文字を超えている
- `publicKey must be valid Base64 encoded` - publicKeyが有効なBase64形式ではない
- `Invalid signature for given payload hash` - 署名がpayloadHashに対して無効

##### 401 Unauthorized - 署名検証失敗

```json
{
  "error": "Invalid signature for given payload hash"
}
```

提供された署名がpayloadHashに対して有効ではありません。署名がメッセージに対して正しく生成されたことを確認してください。

---

## 2. 既存のProposeに署名を追加

### リクエスト

```
PUT /proposes/{id}
Content-Type: application/json
```

#### パスパラメータ

| 項目 | 型 | 説明 |
|------|-----|------|
| `id` | UUID | 署名を追加するPropose ID |

#### リクエストボディ

既存の署名と新しい署名をすべて含めます。

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "payloadHash": "abc123def456",
  "signatures": [
    {
      "publicKey": "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0K...",
      "signature": "MEUCIQD1234567890..."
    },
    {
      "publicKey": "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0K...",
      "signature": "MEUCIQD0987654321..."
    }
  ]
}
```

### レスポンス

#### 成功時 (200 OK)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "payloadHash": "abc123def456",
  "signatureCount": 2,
  "updatedAt": "2026-03-11T10:35:00Z"
}
```

#### エラー時

##### 400 Bad Request

```json
{
  "error": "Invalid UUID format"
}
```

パスのUUID形式が無効です。または入力値が検証ルールに違反しています。

##### 401 Unauthorized

```json
{
  "error": "Invalid signature for given payload hash"
}
```

提供されたいずれかの署名がpayloadHashに対して無効です。

##### 404 Not Found

```json
{
  "error": "Propose not found"
}
```

指定されたIDのProposeが存在しません。

---

## エラーコード一覧

| HTTP Status | 説明 |
|-------------|------|
| 201 | Propose作成成功 |
| 200 | 署名追加成功 |
| 400 | リクエストが無効（入力値検証エラー、無効なUUID形式） |
| 401 | 署名検証に失敗 |
| 404 | Proposeが見つからない |

---

## 検証ルール

このAPIには以下の検証ルールがあります：

### payloadHash
- **最小文字数**: 1
- **最大文字数**: 256

### signatures配列
- **最小個数**: 1
- **最大個数**: 1000

### publicKey
- **最大文字数**: 500
- **形式**: Base64エンコード
- **対応形式**: P256 X.963形式

### signature
- **最大文字数**: 500
- **形式**: Base64エンコード（DER形式）

### 署名の有効性
- 提供されたすべての署名がpayloadHashに対して有効であることが必須です
- 署名はP256の秘密鍵で生成される必要があります

---

## 使用例

### cURL での例

#### 1. Proposeを作成する

```bash
curl -X POST http://localhost:8080/proposes \
  -H "Content-Type: application/json" \
  -d '{
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "payloadHash": "abc123def456",
    "signatures": [
      {
        "publicKey": "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0K...",
        "signature": "MEUCIQD1234567890..."
      }
    ]
  }'
```

#### 2. 署名を追加する

```bash
curl -X PUT http://localhost:8080/proposes/550e8400-e29b-41d4-a716-446655440000 \
  -H "Content-Type: application/json" \
  -d '{
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "payloadHash": "abc123def456",
    "signatures": [
      {
        "publicKey": "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0K...",
        "signature": "MEUCIQD1234567890..."
      },
      {
        "publicKey": "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0K...",
        "signature": "MEUCIQD0987654321..."
      }
    ]
  }'
```

### Swift での例

```swift
import Foundation

// Proposeを作成
let propose = ProposeInput(
  id: UUID(),
  payloadHash: "abc123def456",
  signatures: [
    SignatureInput(
      publicKey: "LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0K...",
      signature: "MEUCIQD1234567890..."
    )
  ]
)

var request = URLRequest(url: URL(string: "http://localhost:8080/proposes")!)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = try JSONEncoder().encode(propose)

let (data, response) = try await URLSession.shared.data(for: request)
print(String(data: data, encoding: .utf8) ?? "")
```

---

## 注意事項

### セキュリティ

- 現在、このAPIには認証機構がありません
- 本番環境での使用前に、適切な認証・認可機構を実装してください
- HTTPS を使用してください
- レート制限を実装することを推奨します

### 署名の生成

- P256 秘密鍵で `payloadHash` に署名してください
- 署名はDER形式でBase64エンコードしてください
- 公開鍵はX.963形式（65バイト）でBase64エンコードしてください

### 同じ公開鍵での複数署名

- 同じ公開鍵で複数の署名を追加することが可能です
- 各署名は独立して検証されます

---

## バージョン

API Version: 1.0.0

最終更新: 2026-03-11
