# WevoSpace

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

WevoSpace is the server-side component of the Wevo approach: a minimal API for storing, synchronizing, and verifying cryptographically signed proposals between parties.

It is not the source of truth. The signatures are.

WevoSpace provides a coordination layer — a place where parties can share and retrieve proposals without either side having to run their own infrastructure. But the validity of any proposal is determined by the signatures it carries, not by the server. Any client can verify signatures independently.

This is one piece of a larger idea: that agreements between people should be recorded as signed history, not as platform-owned data.

---

## Why

When two people make an agreement, the record of that agreement shouldn't live only inside a third-party platform. If that platform shuts down, the evidence goes with it. If it changes its terms, your history becomes subject to new rules you didn't agree to.

The same problem applies to reputation more broadly. Most reputation systems are:

- **Opaque** — you can't see how scores are derived
- **Non-portable** — you can't take your history elsewhere
- **Platform-owned** — the service decides what counts and what doesn't

Trust should be grounded in verifiable history — things that actually happened, signed by the people involved — rather than in scores held on someone else's server.

This is not a new insight. The point of Wevo is to make it practical.

## Core Ideas

- **Signed events, not scores.** A `Propose` is a message with a SHA-256 hash and one or more P-256 signatures. It records what was proposed and who agreed.
- **Local-first ownership.** The server is a coordination layer, not the source of truth. Any client can verify signatures independently without relying on WevoSpace.
- **Portable identity.** Identity is a P-256 key pair. There are no accounts, no passwords. Participation is proven through signatures alone.
- **No token authentication.** The public key *is* the identity. Ownership is proven through signatures, not login sessions.

These are not novel technologies. The value is in applying them to how trust between people is recorded and carried.

## Design Notes / Non-Goals

**Non-goals:**

- Computing reputation scores or rankings
- Acting as an identity provider or authentication system
- Building a social network or discovery layer
- Claiming to be a finalized protocol — this is an exploration, not a spec

**Design choices worth noting:**

- All state transitions are verified server-side via P-256 ECDSA (CryptoKit) — the server cannot be fooled by unsigned requests
- No session state: each request is self-contained and verified independently
- A client that goes offline retains its signed history and can re-sync later

---

## What WevoSpace Does

- Stores proposals (`Propose`) submitted by clients
- Verifies P-256 ECDSA signatures on all state transitions
- Tracks a simple state machine: `proposed → signed → honored / parted / dissolved`
- Exposes a REST API that any Wevo-compatible client can use

WevoSpace does not compute trust scores. It does not rank users or track reputation. It records what happened and verifies that the signatures are valid.

## Current Status

**Experimental / Alpha.**

The core API works. But:

- No formal protocol specification exists yet
- The data format and API may change without notice
- Authentication relies entirely on signature verification — no additional hardening
- Rate limiting is basic
- Not production-hardened

## API Overview

All endpoints are prefixed with `/v1`.

| Method | Path | Description |
|---|---|---|
| `POST` | `/v1/proposes` | Create a propose |
| `GET` | `/v1/proposes/:id` | Get propose details |
| `PATCH` | `/v1/proposes/:id/sign` | Counterparty signs (`proposed → signed`) |
| `DELETE` | `/v1/proposes/:id` | Dissolve (`proposed → dissolved`) |
| `PATCH` | `/v1/proposes/:id/honor` | Honor signature (`signed → honored`) |
| `PATCH` | `/v1/proposes/:id/part` | Part signature (`signed → parted`) |

### State Machine

```
proposed ──sign──→ signed ──honor (both)──→ honored
    │                 │
  dissolve          part (both)
    │                 │
    ↓                 ↓
dissolved           parted
```

Full documentation:
- English: [docs/PROPOSE_API.md](docs/PROPOSE_API.md)
- OpenAPI: [api/propose-api.en.openapi.yaml](api/propose-api.en.openapi.yaml)

## Security Model

- All state transitions require a valid P-256 ECDSA signature from the relevant party
- No login tokens or session management — identity is proven by signature alone
- The server verifies signatures but does not store private keys
- Rate limiting: 60 requests/minute per IP (`X-RateLimit-*` headers on responses)

## Getting Started

### Prerequisites

- Swift 6.0 or later
- SQLite (development, no configuration needed) or PostgreSQL 12+ (production)

### Run Locally

```bash
swift run
# SQLite database is created automatically at db.sqlite
```

### Production (PostgreSQL)

```bash
# Set database connection
export DATABASE_URL=postgres://username:password@localhost:5432/wevospace

# Run migrations
swift run WevoSpace migrate

# Start server
swift run
```

Or with Docker Compose:

```bash
docker-compose up -d postgres
swift run WevoSpace migrate
swift run
```

See [POSTGRESQL_SETUP.md](Sources/WevoSpace/POSTGRESQL_SETUP.md) for details.

### Configuration

Rate limiting and request size are configurable in `configure.swift`:

```swift
app.middleware.use(RateLimitMiddleware(requestLimit: 60, timeWindow: 60))
app.routes.defaultMaxBodySize = "1mb"
```

## Architecture

- Built with [Vapor](https://vapor.codes) (Swift)
- SQLite in development, PostgreSQL in production — switches automatically based on environment
- Signature verification via CryptoKit (P-256), no external crypto dependencies

## API Documentation

- English: [docs/PROPOSE_API.md](docs/PROPOSE_API.md)
- 日本語: [docs/PROPOSE_API_ja.md](docs/PROPOSE_API_ja.md)
- OpenAPI (English): [api/propose-api.en.openapi.yaml](api/propose-api.en.openapi.yaml)
- OpenAPI (日本語): [api/propose-api.openapi.yaml](api/propose-api.openapi.yaml)

## Client Documentation

- Getting Started (English): [docs/notion/getting-started.md](docs/notion/getting-started.md)
- Getting Started (日本語): [docs/notion/getting-started-ja.md](docs/notion/getting-started-ja.md)

---
---

# WevoSpace（日本語）

WevoSpace は Wevo アプローチのサーバー側コンポーネントです。当事者間の暗号学的に署名された提案（Propose）を保存・同期・検証するための、最小限の API です。

真実の源はサーバーではありません。署名です。

WevoSpace は調整のためのレイヤーを提供します。どちらの当事者も自前のインフラを立てることなく、提案を共有・取得できる場所です。しかし、提案の正当性を決めるのはサーバーではなく、提案が持つ署名です。クライアントは署名を独立に検証できます。

これは、より大きなアイデアの一部です。人と人の間の合意は、プラットフォームが所有するデータとしてではなく、署名付きの履歴として記録されるべきだという考え方です。

---

## なぜ作ったか

二者間で合意が成立したとき、その記録がサードパーティのプラットフォームの中にしか存在しないというのは、本来おかしいことです。そのプラットフォームが終われば証拠も消える。ルールが変われば、同意していない新しい基準に自分の履歴が従うことになる。

同じ問題は、より広く「評判」にも当てはまります。多くの評判システムは：

- **不透明** ― スコアがどう算出されるか見えない
- **移植不可** ― 自分の履歴を他の場所に持ち出せない
- **プラットフォーム所有** ― 何が重要で何が重要でないかをサービスが決める

信頼は、誰かのサーバー上のスコアではなく、実際に起きた出来事の検証可能な履歴に基づくべきです。関係者が署名した、実際の出来事として。

これは新しい洞察ではありません。Wevo の目的は、それを実際に使えるものにすることです。

## コアとなる考え方

- **スコアではなく署名付きの出来事。** `Propose`（提案）は SHA-256 ハッシュと P-256 署名を持つメッセージです。何が提案され、誰が合意したかを記録します。
- **ローカルファーストの所有権。** サーバーは調整のためのレイヤーであり、真実の源ではありません。クライアントは WevoSpace に依存せず、署名を独立に検証できます。
- **ポータブルなアイデンティティ。** Identity は P-256 鍵ペアです。アカウントもパスワードもありません。参加の証明は署名のみで行われます。
- **トークン認証なし。** 公開鍵そのものが Identity です。所有権は署名によって証明され、ログインセッションによるものではありません。

これらは新しい技術ではありません。価値は、人と人の間の信頼をどう記録し・携えるかに、これらを組み合わせて適用することにあります。

## 設計メモ / Non-Goals

**Non-Goals（目指していないこと）：**

- 評判スコアやランキングの算出
- Identity プロバイダーや認証システムとして動作すること
- ソーシャルネットワークやディスカバリー層の構築
- 完成したプロトコルとして主張すること ― これは探索であり、仕様ではありません

**設計上の判断：**

- すべての状態遷移はサーバー側で P-256 ECDSA（CryptoKit）により検証される ― 署名なしのリクエストは受け付けない
- セッション状態なし：各リクエストは独立して検証される
- オフラインのクライアントは署名済み履歴をローカルに保持し、後から再同期できる

---

## WevoSpace が行うこと

- クライアントから送信された Propose を保存する
- すべての状態遷移に対して P-256 ECDSA 署名を検証する
- シンプルな状態マシンを管理する：`proposed → signed → honored / parted / dissolved`
- Wevo 互換のクライアントが使用できる REST API を提供する

WevoSpace は信頼スコアを計算しません。ユーザーをランク付けしたり、評判を追跡したりしません。起きたことを記録し、署名が有効であることを確認します。

## 現在の状態

**実験的 / Alpha。**

コアの API は動作します。ただし：

- プロトコルの正式な仕様はまだ存在しません
- データフォーマットと API は予告なく変更される可能性があります
- 認証は署名検証のみに依存しています（追加のセキュリティ対策なし）
- レート制限は基本的なものにとどまっています
- プロダクション向けの堅牢化は行われていません

## API 概要

全エンドポイントは `/v1` プレフィックス付きです。

| メソッド | パス | 説明 |
|---|---|---|
| `GET` | `/v1/proposes` | Propose 一覧（`publicKey`、`status` でフィルタ可） |
| `POST` | `/v1/proposes` | Propose を作成 |
| `GET` | `/v1/proposes/:id` | Propose の詳細取得 |
| `PATCH` | `/v1/proposes/:id/sign` | 相手方が署名（`proposed → signed`） |
| `DELETE` | `/v1/proposes/:id` | 解消（`proposed → dissolved`） |
| `PATCH` | `/v1/proposes/:id/honor` | 履行署名（`signed → honored`） |
| `PATCH` | `/v1/proposes/:id/part` | 解除署名（`signed → parted`） |

### 状態遷移

```
proposed ──sign──→ signed ──honor (両者)──→ honored
    │                 │
  dissolve          part (両者)
    │                 │
    ↓                 ↓
dissolved           parted
```

詳細ドキュメント：
- 英語：[docs/PROPOSE_API.md](docs/PROPOSE_API.md)
- 日本語：[docs/PROPOSE_API_ja.md](docs/PROPOSE_API_ja.md)
- OpenAPI 仕様：[api/propose-api.en.openapi.yaml](api/propose-api.en.openapi.yaml) / [api/propose-api.openapi.yaml](api/propose-api.openapi.yaml)

## セキュリティモデル

- すべての状態遷移は、関係する当事者の有効な P-256 ECDSA 署名を必要とする
- ログイントークンやセッション管理はなし ― Identity は署名のみで証明される
- サーバーは署名を検証するが、秘密鍵は保存しない
- レート制限：IP ごとに 60 リクエスト/分（レスポンスに `X-RateLimit-*` ヘッダーを付与）

## Getting Started

### 前提条件

- Swift 6.0 以降
- SQLite（開発用、設定不要）または PostgreSQL 12+（本番用）

### ローカルで実行

```bash
swift run
# db.sqlite が自動的に作成されます
```

### 本番環境（PostgreSQL）

```bash
# データベース接続を設定
export DATABASE_URL=postgres://username:password@localhost:5432/wevospace

# マイグレーションを実行
swift run WevoSpace migrate

# サーバーを起動
swift run
```

Docker Compose を使う場合：

```bash
docker-compose up -d postgres
swift run WevoSpace migrate
swift run
```

詳細は [POSTGRESQL_SETUP.md](Sources/WevoSpace/POSTGRESQL_SETUP.md) を参照してください。

### 設定

レート制限とリクエストサイズは `configure.swift` で変更できます：

```swift
app.middleware.use(RateLimitMiddleware(requestLimit: 60, timeWindow: 60))
app.routes.defaultMaxBodySize = "1mb"
```

## アーキテクチャ

- [Vapor](https://vapor.codes)（Swift）で構築
- 開発環境は SQLite、本番環境は PostgreSQL ― 環境変数に応じて自動切り替え
- CryptoKit による署名検証（P-256）、外部の暗号ライブラリ依存なし

## クライアントドキュメント

- Getting Started（英語）: [docs/notion/getting-started.md](docs/notion/getting-started.md)
- Getting Started（日本語）: [docs/notion/getting-started-ja.md](docs/notion/getting-started-ja.md)

