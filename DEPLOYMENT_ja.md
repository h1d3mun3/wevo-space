# デプロイガイド

本番環境へのデプロイ方法を説明します。

> English version: [DEPLOYMENT.md](DEPLOYMENT.md)

## 📋 デプロイ前チェックリスト

### 必須項目
- [ ] PostgreSQLデータベースのセットアップ
- [ ] 環境変数の設定
- [ ] HTTPS対応（リバースプロキシ）
- [ ] マイグレーション実行

### 推奨項目
- [ ] ログ監視の設定
- [ ] バックアップ戦略
- [ ] 死活監視（ヘルスチェック）
- [ ] エラートラッキング

---

## クラウドプラットフォーム

### Heroku

#### 1. Heroku CLI のインストール

```bash
brew tap heroku/brew && brew install heroku
heroku login
```

#### 2. アプリケーション作成

```bash
# Herokuアプリ作成
heroku create your-app-name

# PostgreSQLアドオン追加
heroku addons:create heroku-postgresql:mini

# Swiftビルドパック追加
heroku buildpacks:set vapor/vapor
```

#### 3. 環境変数設定

```bash
# 自動的にDATABASE_URLが設定されます
heroku config

# 追加の環境変数
heroku config:set ENVIRONMENT=production
heroku config:set LOG_LEVEL=info
```

#### 4. デプロイ

```bash
git push heroku main

# マイグレーション実行
heroku run WevoSpace migrate --env production

# ログ確認
heroku logs --tail
```

---

### Railway

#### 1. プロジェクト作成

```bash
# Railway CLI のインストール
npm install -g @railway/cli

# ログイン
railway login

# プロジェクト初期化
railway init
```

#### 2. PostgreSQL追加

Railwayダッシュボードから：
1. New → Database → PostgreSQL
2. `DATABASE_URL` が自動的に設定されます

#### 3. デプロイ

```bash
# デプロイ
railway up

# 環境変数確認
railway variables

# ログ確認
railway logs
```

---

### Render

#### 1. render.yaml 作成

```yaml
services:
  - type: web
    name: wevospace
    env: docker
    plan: starter
    buildCommand: swift build -c release
    startCommand: .build/release/WevoSpace serve --env production --hostname 0.0.0.0 --port $PORT
    envVars:
      - key: DATABASE_URL
        fromDatabase:
          name: wevospace-db
          property: connectionString
      - key: ENVIRONMENT
        value: production

databases:
  - name: wevospace-db
    plan: starter
    databaseName: wevospace
    user: vapor
```

#### 2. デプロイ

1. GitHubリポジトリをRenderに接続
2. 自動的にビルド・デプロイが開始
3. マイグレーションは手動で実行：

```bash
# Render Shell から
./WevoSpace migrate --env production
```

---

## VPS / 専用サーバー

### Ubuntu 22.04 での手動セットアップ

#### 1. 依存関係のインストール

```bash
# Swift インストール
wget https://download.swift.org/swift-6.0-release/ubuntu2204/swift-6.0-RELEASE/swift-6.0-RELEASE-ubuntu22.04.tar.gz
tar xzf swift-6.0-RELEASE-ubuntu22.04.tar.gz
sudo mv swift-6.0-RELEASE-ubuntu22.04 /usr/share/swift
echo 'export PATH=/usr/share/swift/usr/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# 必要なパッケージ
sudo apt update
sudo apt install -y git postgresql postgresql-contrib nginx
```

#### 2. PostgreSQL セットアップ

```bash
# PostgreSQL起動
sudo systemctl start postgresql
sudo systemctl enable postgresql

# データベース作成
sudo -u postgres psql <<EOF
CREATE USER vapor WITH PASSWORD 'your-secure-password';
CREATE DATABASE wevospace OWNER vapor;
GRANT ALL PRIVILEGES ON DATABASE wevospace TO vapor;
EOF
```

#### 3. アプリケーションのビルド

```bash
# リポジトリクローン
git clone https://github.com/yourusername/WevoSpace.git
cd WevoSpace

# 環境変数設定
cp .env.example .env
nano .env  # 編集

# ビルド
swift build -c release

# マイグレーション
.build/release/WevoSpace migrate --env production
```

#### 4. Systemd サービス作成

`/etc/systemd/system/wevospace.service`:

```ini
[Unit]
Description=WevoSpace API Server
After=postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=www-data
WorkingDirectory=/var/www/WevoSpace
ExecStart=/var/www/WevoSpace/.build/release/WevoSpace serve --env production --hostname 127.0.0.1 --port 8080
Restart=on-failure
RestartSec=5s

Environment=DATABASE_HOST=localhost
Environment=DATABASE_PORT=5432
Environment=DATABASE_USERNAME=vapor
Environment=DATABASE_PASSWORD=your-secure-password
Environment=DATABASE_NAME=wevospace
Environment=ENVIRONMENT=production

[Install]
WantedBy=multi-user.target
```

起動：

```bash
sudo systemctl daemon-reload
sudo systemctl start wevospace
sudo systemctl enable wevospace
sudo systemctl status wevospace
```

#### 5. Nginx リバースプロキシ

`/etc/nginx/sites-available/wevospace`:

```nginx
server {
    listen 80;
    server_name api.yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

有効化：

```bash
sudo ln -s /etc/nginx/sites-available/wevospace /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

#### 6. SSL証明書の設定（オプション）

HTTPSを使用する場合は、Let's Encryptで無料SSL証明書を取得できます：

```bash
# Certbot インストール
sudo apt install certbot python3-certbot-nginx

# SSL証明書取得（ドメインがある場合）
sudo certbot --nginx -d api.yourdomain.com

# 自動更新設定（既に有効）
sudo systemctl status certbot.timer
```

**Note**: IPアドレスでの運用の場合、SSL証明書は不要です。HTTPで稼働します。

---

## Docker デプロイ

### Dockerfile 作成

```dockerfile
# ビルドステージ
FROM swift:6.0 as build

WORKDIR /build

# 依存関係をコピー
COPY Package.* ./
RUN swift package resolve

# ソースコードをコピー
COPY . .

# リリースビルド
RUN swift build -c release

# 実行ステージ
FROM swift:6.0-slim

WORKDIR /app

# ビルド成果物をコピー
COPY --from=build /build/.build/release/WevoSpace ./WevoSpace

# ポート公開
EXPOSE 8080

# 実行
ENTRYPOINT ["./WevoSpace"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
```

### docker-compose.yml（本番用）

```yaml
version: '3.8'

services:
  app:
    build: .
    restart: always
    ports:
      - "8080:8080"
    environment:
      DATABASE_URL: postgres://vapor:password@postgres:5432/wevospace
      ENVIRONMENT: production
    depends_on:
      - postgres
    networks:
      - wevospace

  postgres:
    image: postgres:15-alpine
    restart: always
    environment:
      POSTGRES_USER: vapor
      POSTGRES_PASSWORD: password
      POSTGRES_DB: wevospace
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - wevospace

volumes:
  postgres_data:

networks:
  wevospace:
    driver: bridge
```

### デプロイ

```bash
# ビルド & 起動
docker-compose up -d

# マイグレーション
docker-compose exec app ./WevoSpace migrate --env production

# ログ確認
docker-compose logs -f app
```

---

## 監視とメンテナンス

### ヘルスチェックエンドポイント

`routes.swift` に追加：

```swift
app.get("health") { req async in
    return ["status": "ok"]
}
```

### ログ監視

```bash
# Systemd
sudo journalctl -u wevospace -f

# Docker
docker-compose logs -f app

# Heroku
heroku logs --tail
```

### データベースバックアップ

```bash
# PostgreSQL バックアップ
pg_dump -U vapor wevospace > backup_$(date +%Y%m%d).sql

# リストア
psql -U vapor wevospace < backup_20260307.sql
```

---

## トラブルシューティング

### アプリケーションが起動しない

```bash
# ログ確認
sudo journalctl -u wevospace -n 100

# データベース接続確認
psql -U vapor -d wevospace -h localhost

# ポート確認
sudo lsof -i :8080
```

### マイグレーションエラー

```bash
# マイグレーション状態確認
./WevoSpace migrate --env production

# 既存のマイグレーションをすべて取り消し
./WevoSpace migrate --revert --all --env production

# 再実行
./WevoSpace migrate --env production
```

### パフォーマンス問題

```bash
# PostgreSQL接続数確認
SELECT count(*) FROM pg_stat_activity;

# スロークエリログ有効化
ALTER SYSTEM SET log_min_duration_statement = 1000;
SELECT pg_reload_conf();
```

---

## セキュリティ推奨事項

### 本番環境

1. ✅ 強力なデータベースパスワード
2. ⚠️ HTTPS推奨（ドメインがある場合）
3. ✅ ファイアウォール設定（UFW等）
4. ✅ 定期的なセキュリティアップデート
5. ✅ 監視・アラート設定
6. ✅ バックアップの自動化

**Note**: IPアドレスでの運用の場合、HTTPで問題ありません。将来的にドメインを取得した際にHTTPSへ移行することを推奨します。

### 環境変数

絶対に公開しないこと：
- `DATABASE_PASSWORD`
- `DATABASE_URL`
- その他の機密情報

---

## 参考リンク

- [Vapor Deployment Guide](https://docs.vapor.codes/deploy/overview/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Nginx Documentation](https://nginx.org/en/docs/)
- [Let's Encrypt](https://letsencrypt.org/)
