#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
cd "$project_dir"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env and configure the Salesforce External Client App first." >&2
  exit 2
fi

set -a
source .env
set +a

: "${SALESFORCE_CLIENT_ID:?SALESFORCE_CLIENT_ID is required}"
: "${SALESFORCE_LOGIN_URL:?SALESFORCE_LOGIN_URL is required}"
: "${SALESFORCE_CALLBACK_URL:?SALESFORCE_CALLBACK_URL is required}"

npm ci
npm run check
npm run build

echo "Installers are under src-tauri/target/release/bundle/."
