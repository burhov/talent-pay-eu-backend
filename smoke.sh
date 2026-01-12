set -euo pipefail
CANON_URL="https://talent-pay-eu-20167237037.europe-west1.run.app"

echo "[1] health"
curl -fsS --max-time 15 "$CANON_URL/health" ; echo

echo "[2] fx"
curl -fsS --max-time 20 "$CANON_URL/fx" | head -c 400 ; echo

echo "[3] api/rates"
curl -fsS --max-time 20 "$CANON_URL/api/rates" | head -c 400 ; echo

echo "[4] api/create-invoice"
INV_JSON="$(curl -fsS --max-time 25 -X POST "$CANON_URL/api/create-invoice" \
  -H "Content-Type: application/json" \
  -d '{"amount":9.90,"currency":"UAH","order_desc":"dbg","order_id":"dbg_001","user_mode":"b2c"}')"
echo "$INV_JSON"

echo "[5] extract invoiceId"
INVOICE_ID="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("invoiceId",""))' <<<"$INV_JSON")"
test -n "$INVOICE_ID"
echo "INVOICE_ID=$INVOICE_ID"

echo "[6] status"
curl -fsS --max-time 20 "$CANON_URL/mono/invoice/status?invoiceId=$INVOICE_ID" ; echo
