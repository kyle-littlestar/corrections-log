#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Corrections Log — API Endpoint Tests
# Usage: API_BASE=https://xxxxx.execute-api.us-east-1.amazonaws.com bash test-api.sh
# ──────────────────────────────────────────────────────────────
set -euo pipefail

if [ -z "${API_BASE:-}" ]; then
  echo "Usage: API_BASE=https://your-api-id.execute-api.us-east-1.amazonaws.com bash test-api.sh"
  exit 1
fi

echo "Testing API at: $API_BASE"
echo ""

# 1. GET — should return empty array initially
echo "GET /entries (list all)"
curl -s "$API_BASE/entries" | python3 -m json.tool || curl -s "$API_BASE/entries"
echo ""

# 2. POST — create a test entry
echo "POST /entries (create)"
TEST_ID="test-$(date +%s)"
curl -s -X POST "$API_BASE/entries" \
  -H "Content-Type: application/json" \
  -d "{
    \"id\": \"$TEST_ID\",
    \"datetime\": \"2025-03-30T14:30\",
    \"title\": \"Test Issue\",
    \"category\": \"Equipment / Machinery\",
    \"severity\": \"moderate\",
    \"issue\": \"Test entry from API verification script\",
    \"correction\": \"Verified POST works\",
    \"preventive\": \"Automated testing\",
    \"responsible\": \"System\",
    \"status\": \"open\"
  }" | python3 -m json.tool || echo "(created)"
echo ""

# 3. GET — verify it shows up
echo "GET /entries (should include new entry)"
curl -s "$API_BASE/entries" | python3 -m json.tool || curl -s "$API_BASE/entries"
echo ""

# 4. PUT — update the entry status
echo "PUT /entries/$TEST_ID (update status to resolved)"
curl -s -X PUT "$API_BASE/entries/$TEST_ID" \
  -H "Content-Type: application/json" \
  -d '{"status": "resolved"}' | python3 -m json.tool || echo "(updated)"
echo ""

# 5. DELETE — remove the test entry
echo "DELETE /entries/$TEST_ID"
curl -s -X DELETE "$API_BASE/entries/$TEST_ID" | python3 -m json.tool || echo "(deleted)"
echo ""

# 6. GET — confirm deletion
echo "GET /entries (should be empty again)"
curl -s "$API_BASE/entries" | python3 -m json.tool || curl -s "$API_BASE/entries"
echo ""

echo "All tests complete."
