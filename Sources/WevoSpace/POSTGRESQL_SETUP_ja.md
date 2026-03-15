# PostgreSQL セットアップガイド

WevoSpaceは開発環境ではSQLite、本番環境ではPostgreSQLを使用します。

> English version: [POSTGRESQL_SETUP.md](POSTGRESQL_SETUP.md)

## 📋 目次

1. [開発環境（SQLite）](#開発環境sqlite)
2. [ローカルPostgreSQL](#ローカルpostgresql)
3. [本番環境（PostgreSQL）](#本番環境postgresql)
4. [Docker Compose](#docker-compose)
5. [マイグレーション](#マイグレーション)

---

## 開発環境（SQLite）

デフォルトでは、開発環境でSQLiteを使用します。環境変数の設定は不要です。

```bash
# アプリケーションを起動
swift run

# 自動的に db.sqlite ファイルが作成されます
```

---

## ローカルPostgreSQL

### 1. PostgreSQLのインストール

#### macOS (Homebrew)
```bash
brew install postgresql@15
brew services start postgresql@15
```

#### Ubuntu/Debian
```bash
sudo apt update
sudo apt install postgresql postgresql-contrib
sudo systemctl start postgresql
```

### 2. データベースとユーザーの作成

```bash
# PostgreSQLに接続
psql postgres

# データベースとユーザーを作成
CREATE USER vapor WITH PASSWORD 'password';
CREATE DATABASE wevospace OWNER vapor;
GRANT ALL PRIVILEGES ON DATABASE wevospace TO vapor;

# 接続確認
\q
psql -U vapor -d wevospace
```

### 3. 環境変数の設定

`.env` ファイルを作成：

```bash
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USERNAME=vapor
DATABASE_PASSWORD=password
DATABASE_NAME=wevospace
```

### 4. アプリケーションの起動

```bash
# マイグレーション実行
swift run WevoSpace migrate

# サーバー起動
swift run
```

---

## 本番環境（PostgreSQL）

### 環境変数の設定方法

#### Option 1: DATABASE_URL を使用（推奨）

Heroku、Railway、Render などのクラウドプラットフォームで一般的：

```bash
export DATABASE_URL="postgres://username:password@hostname:5432/database"
```

#### Option 2: 個別の環境変数

```bash
export DATABASE_HOST="your-postgres-host.com"
export DATABASE_PORT="5432"
export DATABASE_USERNAME="your-username"
export DATABASE_PASSWORD="your-password"
export DATABASE_NAME="wevospace"
export ENVIRONMENT="production"
```

### マイグレーション

```bash
# 本番環境でマイグレーション実行
./WevoSpace migrate --env production
```

---

## Docker Compose

ローカル開発用のDocker Compose設定：

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: wevospace-postgres
    environment:
      POSTGRES_USER: vapor
      POSTGRES_PASSWORD: password
      POSTGRES_DB: wevospace
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U vapor"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
```

### 使用方法

```bash
# PostgreSQLコンテナを起動
docker-compose up -d

# ログ確認
docker-compose logs -f postgres

# 停止
docker-compose down

# データも削除する場合
docker-compose down -v
```

---

## マイグレーション

### マイグレーション実行

```bash
# 開発環境（SQLite）
swift run WevoSpace migrate

# 本番環境（PostgreSQL）
swift run WevoSpace migrate --env production
```

### マイグレーション取り消し

```bash
# 最後のマイグレーションを取り消し
swift run WevoSpace migrate --revert

# すべてのマイグレーションを取り消し
swift run WevoSpace migrate --revert --all
```

### スキーマ確認

```bash
# SQLite
sqlite3 db.sqlite
.tables
.schema proposes

# PostgreSQL
psql -U vapor -d wevospace
\dt
\d proposes
```

### proposes テーブル構造

| カラム | 型 | 説明 |
|---|---|---|
| `id` | UUID | PK（クライアント生成） |
| `content_hash` | TEXT | コンテンツのハッシュ値 |
| `creator_public_key` | TEXT | 作成者の公開鍵 |
| `creator_signature` | TEXT | 作成者の署名 |
| `counterparty_public_key` | TEXT | 相手方の公開鍵 |
| `counterparty_signature` | TEXT? | 相手方の署名 |
| `honor_creator_signature` | TEXT? | 作成者のhonor署名 |
| `honor_counterparty_signature` | TEXT? | 相手方のhonor署名 |
| `part_creator_signature` | TEXT? | 作成者のpart署名 |
| `part_counterparty_signature` | TEXT? | 相手方のpart署名 |
| `status` | TEXT | 状態（proposed/signed/honored/dissolved/parted） |
| `created_at` | TEXT | 作成日時（ISO8601、クライアント生成） |
| `updated_at` | DATETIME? | 最終更新日時（サーバー管理） |

---

## トラブルシューティング

### PostgreSQL接続エラー

```bash
# macOS
brew services list

# Linux
sudo systemctl status postgresql

# Docker
docker-compose ps
```

### 認証エラー

```bash
# PostgreSQLの認証設定を確認
sudo nano /etc/postgresql/15/main/pg_hba.conf
```

### マイグレーションエラー

```bash
# 全マイグレーションをリセットして再実行
swift run WevoSpace migrate --revert --all
swift run WevoSpace migrate
```

---

## データベース起動ログの確認

アプリケーション起動時のログで使用しているデータベースを確認できます：

```
# SQLite
[ INFO ] Using SQLite database (development mode)

# PostgreSQL（DATABASE_URL）
[ INFO ] Using PostgreSQL database from DATABASE_URL

# PostgreSQL（個別設定）
[ INFO ] Using PostgreSQL database: localhost:5432/wevospace
```

---

## セキュリティ注意事項

### 本番環境

1. ✅ 強力なパスワードを使用
2. ✅ TLS/SSL接続を有効化
3. ✅ ファイアウォールでデータベースポートを制限
4. ✅ `.env` ファイルをバージョン管理から除外
5. ✅ データベースユーザーの権限を最小限に

---

## 参考リンク

- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Vapor Database Documentation](https://docs.vapor.codes/fluent/overview/)
- [Fluent PostgreSQL Driver](https://github.com/vapor/fluent-postgres-driver)
