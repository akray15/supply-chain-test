#!/bin/bash 

export AGENT_ID="JCX0ORCEOC"
export AGENT_ALIAS_ID="3EL6WSRCTS"

if [ $# -lt 2 ]; then 
    echo "Usage: $0 <repository> <workflow_file> [branch]"
    echo "Example: $0 akray15/supply-chain-test unpinned-actions-workflow.yml main"
    exit 1
fi

export TARGET_REPOSITORY="$1"
export TARGET_WORKFLOW="$2"
export TARGET_BRANCH="${3:-main}"

echo "=== Github Actions Security Compliance Check ==="
echo "Repository: $TARGET_REPOSITORY"
echo "Workflow File: $TARGET_WORKFLOW"
echo "Branch: $TARGET_BRANCH"
echo "Agent ID: $AGENT_ID"

export AWS_PROFILE="security-staging"

if [ -z "$AGENT_ID" ]; then
    echo "AGENT_ID is not set"
    exit 1
fi

if [ -z "$AGENT_ALIAS_ID" ]; then
    echo "AGENT_ALIAS_ID is not set"
    exit 1
fi

echo "=== AWS Credentials Check ==="
aws sts get-caller-identity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/aws-venv"

if [ ! -d "$VENV_DIR" ]; then
    echo "=== Creating virtual environment ==="
    python3 -m venv "$VENV_DIR"
fi

echo "=== Activating virtual environment ==="
source "$VENV_DIR/bin/activate"

if ! python -c "import boto3" 2>/dev/null; then
    echo "Error: Python boto3 not available. Installing..."
    pip install boto3
fi

echo "=== Invoking Bedrock Agent ==="

python3 << EOF
import boto3
import json
import os
import sys
import uuid

os.environ['AWS_PROFILE'] = '$AWS_PROFILE'

def invoke_agent():
    try: 
        client = boto3.client('bedrock-agent-runtime')

        input_text = "Run security compliance check on: repository: $TARGET_REPOSITORY workflow_file: $TARGET_WORKFLOW branch: $TARGET_BRANCH"

        print("Request:", input_text)
        print("=" * 50)

        session_id = str(uuid.uuid4())
        print(f"Session ID: {session_id}")

        response = client.invoke_agent(
            agentId='$AGENT_ID',
            agentAliasId='$AGENT_ALIAS_ID',
            sessionId=session_id,
            inputText=input_text,
            enableTrace=True
        )

        full_response = ""
        for event in response['completion']:
            if 'chunk' in event and 'bytes' in event['chunk']:
                text = event['chunk']['bytes'].decode('utf-8')
                print(text, end='', flush=True)
                full_response += text
            elif 'trace' in event:
                pass

        with open('compliance-results.txt', 'w') as f:
            f.write(full_response)

        print("\n" + "=" * 50)

        if 'SECURITY STATUS' in full_response.upper():
            if 'PASS' in full_response.upper():
                sys.exit(0)
            elif 'FAIL' in full_response.upper():
                sys.exit(1)

        sys.exit(2)

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(3)

invoke_agent()
EOF

PYTHON_EXIT_CODE=$?

deactivate

echo "=== Results Analysis ==="

if [ -f compliance-results.txt ]; then
    echo "=== Security Compliance Results ==="
    cat compliance-results.txt

    case $PYTHON_EXIT_CODE in
        0)
            echo "COMPLIANCE CHECK: PASSED"
            ;;
        1) 
            echo "COMPLIANCE CHECK: FAILED"
            exit 1
            ;;
        2) 
            echo "COMPLIANCE CHECK: INDETERMINATE"
            ;;
        3) 
            echo "COMPLIANCE CHECK: ERROR"
            exit 1
            ;;
    esac
else
    echo "No results file generated"
    exit 1
fi
