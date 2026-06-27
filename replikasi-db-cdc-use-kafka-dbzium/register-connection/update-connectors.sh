#!/bin/bash

echo "Memulai pembaruan/pendaftaran Debezium Connectors..."
echo "--------------------------------------------"

echo "Mengonfigurasi PostgreSQL Source Connector..."
curl -X PUT -H "Content-Type: application/json" \
     --data @update-postgres-source.json \
     http://localhost:8083/connectors/postgres-source-connector/config
echo -e "\n"

echo "Mengonfigurasi MySQL Sink Connector..."
curl -X PUT -H "Content-Type: application/json" \
     --data @update-mysql-sink.json \
     http://localhost:8083/connectors/mysql-sink-connector/config
echo -e "\n"

echo "--------------------------------------------"
echo "Proses selesai! Silakan cek status di Kafka UI (localhost:8080)"