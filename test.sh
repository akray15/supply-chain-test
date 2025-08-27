export AGENT_ID="JCX0ORCEOC"
export AGENT_ALIAS_ID="3EL6WSRCTS"

export TARGET_REPOSITORY="akray15/supply-chain-test"
export TARGET_WORKFLOW="unpinned-actions-workflow.yml"
export TARGET_BRANCH="main"

echo "=== Github Actions Security Compliance Check ==="
echo "Repository: $TARGET_REPOSITORY"
echo "Workflow File: $TARGET_WORKFLOW"
echo "Branch: $TARGET_BRANCH"
echo "Agent ID: $AGENT_ID"

export AWS_PROFILE="security-staging"

# Verify we have the required values
if [ -z "$AGENT_ID" ]; then
  echo "AGENT_ID is not set"
  exit 1
fi

if [ -z "$AGENT_ALIAS_ID" ]; then
  echo "AGENT_ALIAS_ID is not set"
  exit 1
fi

REQUEST_TEXT="Run security compliance check on: repository: $TARGET_REPOSITORY workflow_file: $TARGET_WORKFLOW branch: $TARGET_BRANCH"

echo "=== Creating Bedrock Agent Session ==="

echo "=== CREDENTIAL DEBUG ==="
echo "AWS_PROFILE: $AWS_PROFILE"
echo "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:10}..." 
echo "AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:0:10}..."
echo "AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
echo "AWS_REGION: $AWS_REGION"
aws configure list
aws sts get-caller-identity
echo "========================="

# Step 1: Create session
SESSION_ID=$(aws bedrock-agent-runtime create-session --query 'sessionId' --output text)

if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "None" ]; then
  echo "Failed to create session"
  exit 1
fi

echo "Created session: $SESSION_ID"

# Step 2: Create invocation

echo "=== Creating Invocation ==="

INVOCATION_ID=$(aws bedrock-agent-runtime create-invocation --session-identifier $SESSION_ID --query invocationId --output text)

if [ -z "$INVOCATION_ID" ] || [ "$INVOCATION_ID" = "None" ]; then
  echo "Failed to create invocation"
  exit 1
fi 

echo "Created invocation: $INVOCATION_ID"

# Put the invocation step 

echo "=== Sending request to Agent ==="
echo "Request Text: $REQUEST_TEXT"

PAYLOAD_JSON=$(cat << EOF
{
  "contentBlocks": [
    {
      "text": "$REQUEST_TEXT"
    }
  ]
}
EOF
)

CURRENT_TIME=$(date -u -Iseconds)

aws bedrock-agent-runtime put-invocation-step --session-identifier $SESSION_ID --invocation-identifier $INVOCATION_ID --invocation-step-time "$CURRENT_TIME" --payload "$PAYLOAD_JSON"  --output json > put-step-response.json

if [ ! -f put-step-response.json ]; then
  echo "Failed to put invocation step"
  exit 1
fi 

echo "=== Put Step Response ==="
cat put-step-response.json

# Step 3: Wait for processing and get results

echo "=== Waiting for results ==="
sleep 10  # Wait for processing

# Get invocation steps/results
echo "=== Getting Results ==="

aws bedrock-agent-runtime list-invocation-steps --session-identifier $SESSION_ID --invocation-identifier $INVOCATION_ID --output json > invocation-steps.json

if [ -f invocation-steps.json ]; then
  echo "=== Raw JSON Response ==="
  cat invocation-steps.json | jq '.'
   
  echo "=== JSON Structure Analysis ==="
  echo "Keys in response:"
  cat invocation-steps.json | jq 'keys'
   
  echo "InvocationSteps array length:"
  cat invocation-steps.json | jq '.invocationStepSummaries | length'
   
  if [ "$(cat invocation-steps.json | jq '.invocationStepSummaries | length')" -gt 0 ]; then
    echo "First invocation step structure:"
    cat invocation-steps.json | jq '.invocationStepSummaries[0]'
  fi
   
  echo "=== Attempting to Extract Results ==="
  
  if [ "$(cat invocation-steps.json | jq '.invocationStepSummaries | length')" -gt 0 ]; then
    echo "=== Found invocation steps, getting detailed response"

    for step_id in $(cat invocation-steps.json | jq -r '.invocationStepSummaries[].invocationStepId'); do
      echo "=== Getting detailed step: $step_id ==="

      aws bedrock-agent-runtime get-invocation-step --session-identifier $SESSION_ID --invocation-identifier $INVOCATION_ID --invocation-step-id $step_id --output json > step-detail-$step_id.json

      if [ -f step-detail-$step_id.json ]; then
        echo "=== Step Detail Reponse ==="
        cat step-detail-$step_id.json | jq '.'

        STEP_RESPONSE=$(cat step-detail-$step_id.json | jq -r '.response.text // .response.content // .output.text // .payload.contentBlocks[]?.text // empty' 2>/dev/null)

        if [ -n "$STEP_RESPONSE" ]; then
          echo "=== Security Compliance Results Found ==="
          echo "$STEP_RESPONSE" > compliance-results.txt
          cat compliance-results.txt
          break
        else 
          echo "=== No response text found in this step, checking payload structure ==="
          cat step-detail-$step_id.json | jq '.payload // .response // empty'
        fi
      else
        echo "Failed to get step detail for $step_id"
      fi
    done 
  else 
    echo "=== No invocation steps found yet ==="
  fi

  # Check if pass or fail 

  if grep -q "SECURITY STATUS.*PASS" compliance-results.txt; then 
    echo "COMPLIANCE CHECK: PASSED" 
    #echo "COMPLIANCE_STATUS=PASS" >> $GITHUB_ENV
  elif grep -q "SECURITY STATUS.*FAIL" compliance-results.txt; then 
    echo "COMPLIANCE CHECK: FAILED"
    #echo "COMPLIANCE_STATUS=FAIL" >> $GITHUB_ENV
  else
    echo "COMPLIANCE CHECK: INDETERMINATE"
    #echo "COMPLIANCE_STATUS=UNKNOWN" >> $GITHUB_ENV
  fi
else 
  echo "No results received"
  #echo "COMPLIANCE_STATUS=ERROR" >> $GITHUB_ENV
  exit 1
fi 

