# WevoSpace

💧 Vapor Web フレームワークで構築したプロジェクトです。

多者間の合意を暗号署名で記録・管理するAPIサーバーです（1 creator : n counterparties）。

> English version: [README.md](README.md)

## Features

### 🔒 セキュリティ
- **署名検証**: P-256 ECDSA による全状態遷移の検証
- **レート制限**: IPアドレスごとに60リクエスト/分
- **リクエストサイズ制限**: 最大1MB/リクエスト
- **重複チェック**: Propose IDの重複を防止

### 📡 API エンドポイント

全エンドポイントに `/v1` プレフィックスが付きます。

| メソッド | パス | 説明 |
|---|---|---|
| `POST` | `/v1/proposes` | Propose作成 |
| `GET` | `/v1/proposes/:id` | Propose詳細取得 |
| `PATCH` | `/v1/proposes/:id/sign` | 相手方署名（proposed → signed） |
| `DELETE` | `/v1/proposes/:id` | 解消（proposed → dissolved） |
| `PATCH` | `/v1/proposes/:id/honor` | Honor署名（signed → honored） |
| `PATCH` | `/v1/proposes/:id/part` | Part署名（signed → parted） |

### 状態遷移

```
proposed ──sign（全相手方）──→ signed ──honor（全員）──→ honored
    │                              │
  dissolve                      part（いずれか1人→即座に遷移）
    │                              │
    ↓                              ↓
dissolved                       parted
```

レート制限ヘッダー:
- `X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset`
- 制限超過時: `429 Too Many Requests` + `Retry-After`

詳細は [docs/PROPOSE_API_ja.md](docs/PROPOSE_API_ja.md) / [docs/PROPOSE_API.md](docs/PROPOSE_API.md)（英語）を参照してください。

---

## Getting Started

### 必要環境

- Swift 6.0 以降
- PostgreSQL 12+（本番環境）
- Docker & Docker Compose（任意、ローカルPostgreSQL用）

### データベースのセットアップ

WevoSpaceは開発環境でSQLite、本番環境でPostgreSQLを使用します。

#### 開発環境（SQLite — デフォルト）

設定不要です。

```bash
swift run
# 自動的に db.sqlite が作成されます
```

#### 本番環境（PostgreSQL）

詳細は [POSTGRESQL_SETUP_ja.md](Sources/WevoSpace/POSTGRESQL_SETUP_ja.md) を参照してください。

Dockerを使ったクイックスタート:

```bash
# PostgreSQL起動
docker-compose up -d postgres

# マイグレーション実行
swift run WevoSpace migrate

# サーバー起動
swift run
```

### ビルド・実行

```bash
# ビルド
swift build

# サーバー起動
swift run

# テスト
swift test
```

---

## Configuration

### 環境変数

```bash
# PostgreSQL（本番環境）
DATABASE_URL=postgres://username:password@localhost:5432/wevospace

# または個別変数で指定
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USERNAME=vapor
DATABASE_PASSWORD=password
DATABASE_NAME=wevospace
```

### レート制限

`configure.swift` で設定できます:

```swift
app.middleware.use(RateLimitMiddleware(requestLimit: 60, timeWindow: 60))
app.routes.defaultMaxBodySize = "1mb"
```

---

## Architecture

### データベース

- **開発**: SQLite（設定不要）
- **本番**: PostgreSQL（推奨）

環境に応じて自動的に切り替わります。

### データモデル

**Propose** — 多者間合意の本体（1 creator : n counterparties）

| フィールド | 説明 |
|---|---|
| `contentHash` | コンテンツのハッシュ値 |
| `creatorPublicKey` / `creatorSignature` | 作成者の鍵と署名 |
| `honorCreatorSignature` / `honorCreatorTimestamp` | 作成者のhonor署名 |
| `partCreatorSignature` / `partCreatorTimestamp` | 作成者のpart署名 |
| `dissolvedAt` | 解消タイムスタンプ |
| `status` | 現在の状態 |
| `signatureVersion` | 署名スキームバージョン（現行: 1） |
| `createdAt` | 作成日時（クライアント生成） |
| `updatedAt` | 最終更新日時（サーバー管理） |

**ProposeCounterparty** — 各相手方の署名情報（別テーブル、1:n）

| フィールド | 説明 |
|---|---|
| `publicKey` | 相手方の公開鍵（JWK形式） |
| `signSignature` / `signTimestamp` | /sign の署名 |
| `honorSignature` / `honorTimestamp` | /honor の署名 |
| `partSignature` / `partTimestamp` | /part の署名 |

### セキュリティ原則

1. 全状態遷移は P-256 ECDSA 署名検証で担保
2. 認証トークン不要 — 公開鍵が参加者であることを署名で証明
3. サーバーはステートレスな検証のみ担当

---

## API ドキュメント

- 日本語: [docs/PROPOSE_API_ja.md](docs/PROPOSE_API_ja.md)
- English: [docs/PROPOSE_API.md](docs/PROPOSE_API.md)
- OpenAPI (日本語): [api/propose-api.openapi.yaml](api/propose-api.openapi.yaml)
- OpenAPI (English): [api/propose-api.en.openapi.yaml](api/propose-api.en.openapi.yaml)

## 参考リンク

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
