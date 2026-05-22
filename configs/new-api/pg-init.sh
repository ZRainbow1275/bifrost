#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL 15 revokes implicit CREATE on public from ordinary users.
# NewAPI relies on GORM AutoMigrate, so grant schema privileges at init time.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    GRANT ALL ON SCHEMA public TO "$POSTGRES_USER";
EOSQL
