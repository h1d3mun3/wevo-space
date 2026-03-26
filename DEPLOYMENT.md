# Deployment Guide

This guide explains how to deploy WevoSpace to production.

> 日本語版: [DEPLOYMENT_ja.md](DEPLOYMENT_ja.md)

## 📋 Pre-Deployment Checklist

### Required
- [ ] PostgreSQL database setup
- [ ] Environment variables configured
- [ ] HTTPS configured (reverse proxy)
- [ ] Migrations run

### Recommended
- [ ] Log monitoring configured
- [ ] Backup strategy in place
- [ ] Health check / uptime monitoring
- [ ] Error tracking

---

## Cloud Platforms

### Heroku

#### 1. Install Heroku CLI

```bash
brew tap heroku/brew && brew install heroku
heroku login
```

#### 2. Create Application

```bash
# Create Heroku app
heroku create your-app-name

# Add PostgreSQL add-on
heroku addons:create heroku-postgresql:mini

# Add Swift buildpack
heroku buildpacks:set vapor/vapor
```

#### 3. Configure Environment Variables

```bash
# DATABASE_URL is set automatically
heroku config

# Additional environment variables
heroku config:set ENVIRONMENT=production
heroku config:set LOG_LEVEL=info
```

#### 4. Deploy

```bash
git push heroku main

# Run migrations
heroku run WevoSpace migrate --env production

# View logs
heroku logs --tail
```

---

### Railway

#### 1. Create Project

```bash
# Install Railway CLI
npm install -g @railway/cli

# Login
railway login

# Initialize project
railway init
```

#### 2. Add PostgreSQL

From the Railway dashboard:
1. New → Database → PostgreSQL
2. `DATABASE_URL` is set automatically

#### 3. Deploy

```bash
# Deploy
railway up

# Check environment variables
railway variables

# View logs
railway logs
```

---

### Render

#### 1. Create render.yaml

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

#### 2. Deploy

1. Connect your GitHub repository to Render
2. Build and deploy starts automatically
3. Run migrations manually:

```bash
# From Render Shell
./WevoSpace migrate --env production
```

---

## VPS / Dedicated Server

### Manual Setup on Ubuntu 22.04

#### 1. Install Dependencies

```bash
# Install Swift
wget https://download.swift.org/swift-6.0-release/ubuntu2204/swift-6.0-RELEASE/swift-6.0-RELEASE-ubuntu22.04.tar.gz
tar xzf swift-6.0-RELEASE-ubuntu22.04.tar.gz
sudo mv swift-6.0-RELEASE-ubuntu22.04 /usr/share/swift
echo 'export PATH=/usr/share/swift/usr/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# Required packages
sudo apt update
sudo apt install -y git postgresql postgresql-contrib nginx
```

#### 2. PostgreSQL Setup

```bash
# Start PostgreSQL
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Create database
sudo -u postgres psql <<EOF
CREATE USER vapor WITH PASSWORD 'your-secure-password';
CREATE DATABASE wevospace OWNER vapor;
GRANT ALL PRIVILEGES ON DATABASE wevospace TO vapor;
EOF
```

#### 3. Build the Application

```bash
# Clone repository
git clone https://github.com/yourusername/WevoSpace.git
cd WevoSpace

# Configure environment
cp .env.example .env
nano .env  # edit as needed

# Build
swift build -c release

# Run migrations
.build/release/WevoSpace migrate --env production
```

#### 4. Create Systemd Service

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

Start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl start wevospace
sudo systemctl enable wevospace
sudo systemctl status wevospace
```

#### 5. Nginx Reverse Proxy

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

Enable:

```bash
sudo ln -s /etc/nginx/sites-available/wevospace /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

#### 6. SSL Certificate (Optional)

If you have a domain, obtain a free SSL certificate from Let's Encrypt:

```bash
# Install Certbot
sudo apt install certbot python3-certbot-nginx

# Obtain SSL certificate
sudo certbot --nginx -d api.yourdomain.com

# Auto-renewal is already enabled
sudo systemctl status certbot.timer
```

**Note**: If running on an IP address only, SSL is not required and HTTP is sufficient.

---

## Docker Deployment

### Dockerfile

```dockerfile
# Build stage
FROM swift:6.0 as build

WORKDIR /build

# Copy dependencies
COPY Package.* ./
RUN swift package resolve

# Copy source
COPY . .

# Release build
RUN swift build -c release

# Run stage
FROM swift:6.0-slim

WORKDIR /app

# Copy build artifact
COPY --from=build /build/.build/release/WevoSpace ./WevoSpace

# Expose port
EXPOSE 8080

# Run
ENTRYPOINT ["./WevoSpace"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
```

### docker-compose.yml (Production)

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

### Deploy

```bash
# Build & start
docker-compose up -d

# Run migrations
docker-compose exec app ./WevoSpace migrate --env production

# View logs
docker-compose logs -f app
```

---

## Monitoring & Maintenance

### Health Check Endpoint

The `/health` endpoint is already implemented in `routes.swift` and returns the server status and current timestamp:

```
GET /health
→ {"status": "ok", "timestamp": "1711234567.0"}
```

### Log Monitoring

```bash
# Systemd
sudo journalctl -u wevospace -f

# Docker
docker-compose logs -f app

# Heroku
heroku logs --tail
```

### Database Backup

```bash
# PostgreSQL backup
pg_dump -U vapor wevospace > backup_$(date +%Y%m%d).sql

# Restore
psql -U vapor wevospace < backup_20260307.sql
```

---

## Troubleshooting

### Application Won't Start

```bash
# Check logs
sudo journalctl -u wevospace -n 100

# Check database connection
psql -U vapor -d wevospace -h localhost

# Check port
sudo lsof -i :8080
```

### Migration Errors

```bash
# Check migration status
./WevoSpace migrate --env production

# Revert all migrations
./WevoSpace migrate --revert --all --env production

# Re-run
./WevoSpace migrate --env production
```

### Performance Issues

```bash
# Check PostgreSQL connection count
SELECT count(*) FROM pg_stat_activity;

# Enable slow query logging
ALTER SYSTEM SET log_min_duration_statement = 1000;
SELECT pg_reload_conf();
```

---

## Security Recommendations

### Production

1. ✅ Use strong database passwords
2. ⚠️ HTTPS recommended (if you have a domain)
3. ✅ Firewall configuration (UFW, etc.)
4. ✅ Regular security updates
5. ✅ Monitoring and alerting
6. ✅ Automated backups

**Note**: Running on an IP address only, HTTP is acceptable. Migrating to HTTPS is recommended when a domain is obtained.

### Environment Variables

Never expose the following:
- `DATABASE_PASSWORD`
- `DATABASE_URL`
- Any other sensitive credentials

---

## References

- [Vapor Deployment Guide](https://docs.vapor.codes/deploy/overview/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Nginx Documentation](https://nginx.org/en/docs/)
- [Let's Encrypt](https://letsencrypt.org/)
