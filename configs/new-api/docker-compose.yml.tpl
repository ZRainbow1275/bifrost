services:
  new-api:
    image: ${BIFROST_NEW_API_IMAGE:-calciumion/new-api:v1.0.0-rc.6}
    container_name: new-api
    restart: always
    ports:
      - "${BIFROST_SERVER_B_WG_IP:-10.8.0.2}:3000:3000"
    environment:
      SQL_DSN: "postgres://newapi:${BIFROST_NEW_API_POSTGRES_PASSWORD}@postgres:5432/newapi?sslmode=disable"
      REDIS_CONN_STRING: "redis://redis:6379"
      SQL_MAX_OPEN_CONNS: "50"
      SQL_MAX_IDLE_CONNS: "10"
      SESSION_SECRET: "${SESSION_SECRET}"
      TZ: "Asia/Shanghai"
    volumes:
      - /var/lib/new-api/data:/data
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started

  postgres:
    image: postgres:15
    container_name: new-api-pg
    restart: always
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: ${BIFROST_NEW_API_POSTGRES_PASSWORD}
      POSTGRES_DB: newapi
    volumes:
      - /var/lib/new-api-pg:/var/lib/postgresql/data
      - ./pg-init.sh:/docker-entrypoint-initdb.d/00-init.sh:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U newapi -d newapi -h 127.0.0.1"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 10s

  redis:
    image: redis:7-alpine
    container_name: new-api-redis
    restart: always
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /var/lib/new-api-redis:/data
