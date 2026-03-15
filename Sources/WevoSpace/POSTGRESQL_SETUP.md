# PostgreSQL Setup Guide

WevoSpace uses SQLite in development and PostgreSQL in production.

> 日本語版: [POSTGRESQL_SETUP_ja.md](POSTGRESQL_SETUP_ja.md)

## 📋 Table of Contents

1. [Development (SQLite)](#development-sqlite)
2. [Local PostgreSQL](#local-postgresql)
3. [Production (PostgreSQL)](#production-postgresql)
4. [Docker Compose](#docker-compose)
5. [Migrations](#migrations)

---

## Development (SQLite)

By default, SQLite is used in development. No environment variables needed.

```bash
# Start the application
swift run

# db.sqlite is created automatically
```

---

## Local PostgreSQL

### 1. Install PostgreSQL

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

### 2. Create Database and User

```bash
# Connect to PostgreSQL
psql postgres

# Create database and user
CREATE USER vapor WITH PASSWORD 'password';
CREATE DATABASE wevospace OWNER vapor;
GRANT ALL PRIVILEGES ON DATABASE wevospace TO vapor;

# Verify connection
\q
psql -U vapor -d wevospace
```

### 3. Configure Environment Variables

Create a `.env` file:

```bash
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USERNAME=vapor
DATABASE_PASSWORD=password
DATABASE_NAME=wevospace
```

### 4. Start the Application

```bash
# Run migrations
swift run WevoSpace migrate

# Start server
swift run
```

---

## Production (PostgreSQL)

### Configuration Options

#### Option 1: DATABASE_URL (recommended)

Common on cloud platforms like Heroku, Railway, and Render:

```bash
export DATABASE_URL="postgres://username:password@hostname:5432/database"
```

#### Option 2: Individual Environment Variables

```bash
export DATABASE_HOST="your-postgres-host.com"
export DATABASE_PORT="5432"
export DATABASE_USERNAME="your-username"
export DATABASE_PASSWORD="your-password"
export DATABASE_NAME="wevospace"
export ENVIRONMENT="production"
```

### Migrations

```bash
# Run migrations in production
./WevoSpace migrate --env production
```

---

## Docker Compose

Docker Compose configuration for local development:

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

### Usage

```bash
# Start PostgreSQL container
docker-compose up -d

# View logs
docker-compose logs -f postgres

# Stop
docker-compose down

# Stop and remove volumes
docker-compose down -v
```

---

## Migrations

### Run Migrations

```bash
# Development (SQLite)
swift run WevoSpace migrate

# Production (PostgreSQL)
swift run WevoSpace migrate --env production
```

### Revert Migrations

```bash
# Revert last migration
swift run WevoSpace migrate --revert

# Revert all migrations
swift run WevoSpace migrate --revert --all
```

### Inspect Schema

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

### proposes Table Schema

| Column | Type | Description |
|---|---|---|
| `id` | UUID | PK (client-generated) |
| `content_hash` | TEXT | Hash of the content |
| `creator_public_key` | TEXT | Creator's public key |
| `creator_signature` | TEXT | Creator's signature |
| `counterparty_public_key` | TEXT | Counterparty's public key |
| `counterparty_signature` | TEXT? | Counterparty's signature |
| `honor_creator_signature` | TEXT? | Creator's honor signature |
| `honor_counterparty_signature` | TEXT? | Counterparty's honor signature |
| `part_creator_signature` | TEXT? | Creator's part signature |
| `part_counterparty_signature` | TEXT? | Counterparty's part signature |
| `status` | TEXT | State (proposed/signed/honored/dissolved/parted) |
| `created_at` | TEXT | Creation timestamp (ISO8601, client-generated) |
| `updated_at` | DATETIME? | Last updated timestamp (server-managed) |

---

## Troubleshooting

### PostgreSQL Connection Error

```bash
# macOS
brew services list

# Linux
sudo systemctl status postgresql

# Docker
docker-compose ps
```

### Authentication Error

```bash
# Check PostgreSQL authentication config
sudo nano /etc/postgresql/15/main/pg_hba.conf
```

### Migration Error

```bash
# Reset and re-run all migrations
swift run WevoSpace migrate --revert --all
swift run WevoSpace migrate
```

---

## Startup Log

The application logs which database is in use at startup:

```
# SQLite
[ INFO ] Using SQLite database (development mode)

# PostgreSQL (DATABASE_URL)
[ INFO ] Using PostgreSQL database from DATABASE_URL

# PostgreSQL (individual variables)
[ INFO ] Using PostgreSQL database: localhost:5432/wevospace
```

---

## Security Notes

### Production

1. ✅ Use strong passwords
2. ✅ Enable TLS/SSL connections
3. ✅ Restrict database port with a firewall
4. ✅ Exclude `.env` from version control
5. ✅ Grant minimum necessary privileges to the database user

---

## References

- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Vapor Database Documentation](https://docs.vapor.codes/fluent/overview/)
- [Fluent PostgreSQL Driver](https://github.com/vapor/fluent-postgres-driver)
