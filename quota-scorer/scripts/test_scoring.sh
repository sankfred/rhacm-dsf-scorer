#!/bin/bash

curl -sk -X POST "https://localhost:8000/scoring" \
  -H "Content-Type: application/json" \
  -d @data.json | jq
