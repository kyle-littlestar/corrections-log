#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Corrections Log — AWS Deployment Script
# Run from WSL:  cd /mnt/d/\[AI\]/Claude-Code/Projects/corrections-log/aws && bash deploy.sh
# Prerequisites: AWS CLI configured, zip installed
# ──────────────────────────────────────────────────────────────
set -euo pipefail

REGION="us-east-1"
TABLE_NAME="corrections-log-entries"
ROLE_NAME="corrections-log-lambda-role"
FUNCTION_NAME="corrections-log-api"
API_NAME="corrections-log-api"

echo "============================================"
echo "  Corrections Log — AWS Backend Deployment"
echo "============================================"

# ── 1. DynamoDB Table ──
echo ""
echo "Step 1: Creating DynamoDB table..."
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" &>/dev/null; then
  echo "  Table '$TABLE_NAME' already exists — skipping."
else
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions \
      AttributeName=userId,AttributeType=S \
      AttributeName=id,AttributeType=S \
    --key-schema \
      AttributeName=userId,KeyType=HASH \
      AttributeName=id,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
  echo "  Table '$TABLE_NAME' created (on-demand)."
  echo "  Waiting for table to become active..."
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
  echo "  Table is active."
fi

# ── 2. IAM Role ──
echo ""
echo "Step 2: Creating IAM role..."
ROLE_ARN=""
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
  echo "  Role '$ROLE_NAME' already exists — $ROLE_ARN"
else
  ROLE_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --query 'Role.Arn' --output text)
  echo "  Role created — $ROLE_ARN"
fi

# Attach the DynamoDB + CloudWatch policy
POLICY_NAME="corrections-log-dynamo-policy"
POLICY_ARN=""

EXISTING_POLICY=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text)
if [ -n "$EXISTING_POLICY" ] && [ "$EXISTING_POLICY" != "None" ]; then
  POLICY_ARN="$EXISTING_POLICY"
  echo "  Policy '$POLICY_NAME' already exists — $POLICY_ARN"
else
  POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document file://dynamo-policy.json \
    --query 'Policy.Arn' --output text)
  echo "  Policy created — $POLICY_ARN"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
echo "  Policy attached to role."

echo "  Waiting 10s for IAM propagation..."
sleep 10

# ── 3. Lambda Function ──
echo ""
echo "Step 3: Deploying Lambda function..."

cd lambda
zip -j ../function.zip index.mjs
cd ..

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &>/dev/null; then
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://function.zip \
    --region "$REGION" > /dev/null
  echo "  Lambda function updated."
else
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime nodejs20.x \
    --role "$ROLE_ARN" \
    --handler index.handler \
    --zip-file fileb://function.zip \
    --timeout 10 \
    --memory-size 128 \
    --environment "Variables={TABLE_NAME=$TABLE_NAME}" \
    --region "$REGION" > /dev/null
  echo "  Lambda function created."
fi

echo "  Waiting for function to become active..."
aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null || \
  aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null || \
  sleep 5
echo "  Lambda is active."

rm -f function.zip

# ── 4. API Gateway (HTTP API) ──
echo ""
echo "Step 4: Creating API Gateway (HTTP API)..."

API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId" --output text 2>/dev/null || echo "")

if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  echo "  API '$API_NAME' already exists — ID: $API_ID"
else
  API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --cors-configuration '{
      "AllowOrigins": ["*"],
      "AllowMethods": ["GET","POST","PUT","DELETE","OPTIONS"],
      "AllowHeaders": ["Content-Type"],
      "MaxAge": 86400
    }' \
    --region "$REGION" \
    --query 'ApiId' --output text)
  echo "  API created — ID: $API_ID"
fi

LAMBDA_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text)

INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query 'Items[0].IntegrationId' --output text 2>/dev/null || echo "")

if [ -z "$INTEGRATION_ID" ] || [ "$INTEGRATION_ID" == "None" ]; then
  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$LAMBDA_ARN" \
    --payload-format-version "2.0" \
    --region "$REGION" \
    --query 'IntegrationId' --output text)
  echo "  Integration created — $INTEGRATION_ID"
else
  echo "  Integration exists — $INTEGRATION_ID"
fi

EXISTING_ROUTES=$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
  --query 'Items[*].RouteKey' --output text 2>/dev/null || echo "")

for ROUTE in "GET /entries" "POST /entries" "PUT /entries/{id}" "DELETE /entries/{id}"; do
  if echo "$EXISTING_ROUTES" | grep -qF "$ROUTE"; then
    echo "  Route '$ROUTE' already exists."
  else
    aws apigatewayv2 create-route \
      --api-id "$API_ID" \
      --route-key "$ROUTE" \
      --target "integrations/$INTEGRATION_ID" \
      --region "$REGION" > /dev/null
    echo "  Route '$ROUTE' created."
  fi
done

STAGE_EXISTS=$(aws apigatewayv2 get-stages --api-id "$API_ID" --region "$REGION" \
  --query "Items[?StageName=='\$default'].StageName" --output text 2>/dev/null || echo "")

if [ -z "$STAGE_EXISTS" ] || [ "$STAGE_EXISTS" == "None" ]; then
  aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$REGION" > /dev/null
  echo "  Default stage created with auto-deploy."
else
  echo "  Default stage already exists."
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
STATEMENT_ID="apigateway-invoke-${API_ID}"

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "$STATEMENT_ID" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
  --region "$REGION" 2>/dev/null || echo "  Lambda permission already exists."

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"

echo ""
echo "============================================"
echo "  DEPLOYMENT COMPLETE"
echo "============================================"
echo ""
echo "  API Base URL:  $API_URL"
echo ""
echo "  Test with:"
echo "    curl ${API_URL}/entries"
echo ""
echo "  Update your index.html:"
echo "    const API_BASE = '${API_URL}';"
echo ""
echo "============================================"
