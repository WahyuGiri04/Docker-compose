#!/bin/bash

echo "Memulai pendaftaran Debezium Connectors..."

# 1. Daftarkan Postgres Source
echo "--------------------------------------------"
echo "Mendaftarkan PostgreSQL Source Connector..."
curl -i -X POST \
  -H "Accept:application/json" \
  -H "Content-Type:application/json" \
  http://localhost:8083/connectors/ \
  -d @postgres-source.json

echo -e "\n"

# 2. Daftarkan MySQL Sink
echo "--------------------------------------------"
echo "Mendaftarkan MySQL Sink Connector..."
curl -i -X POST \
  -H "Accept:application/json" \
  -H "Content-Type:application/json" \
  http://localhost:8083/connectors/ \
  -d @mysql-sink.json

echo -e "\n--------------------------------------------"
echo "Proses selesai! Silakan cek status di Kafka UI (localhost:8080)"