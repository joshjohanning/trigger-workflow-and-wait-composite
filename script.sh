#!/usr/bin/env bash
set -e

# set -exo pipefail

usage_docs() {
  echo ""
  echo "You can use this Github Action with:"
  echo "- uses: joshjohanning/trigger-workflow-and-wait-composite@main"
  echo "  with:"
  echo "    owner: joshjohanning"
  echo "    repo: myrepo"
  echo "    github_token: \${{ secrets.GITHUB_PERSONAL_ACCESS_TOKEN }}"
  echo "    workflow_file_name: main.yaml"
}
GITHUB_API_URL="${API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}"

validate_args() {
  wait_interval=10 # Waits for 10 seconds
  if [ "${INPUT_WAIT_INTERVAL}" ]
  then
    wait_interval=${INPUT_WAIT_INTERVAL}
  fi

  propagate_failure=true
  if [ -n "${INPUT_PROPAGATE_FAILURE}" ]
  then
    propagate_failure=${INPUT_PROPAGATE_FAILURE}
  fi

  trigger_workflow=true
  if [ -n "${INPUT_TRIGGER_WORKFLOW}" ]
  then
    trigger_workflow=${INPUT_TRIGGER_WORKFLOW}
  fi

  wait_workflow=true
  if [ -n "${INPUT_WAIT_WORKFLOW}" ]
  then
    wait_workflow=${INPUT_WAIT_WORKFLOW}
  fi

  if [ -z "${INPUT_OWNER}" ]
  then
    echo "Error: Owner is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_REPO}" ]
  then
    echo "Error: Repo is a required argument."
    usage_docs
    exit 1
  fi

  # checks to see if either 1. Github token is provided or 2. Github App and the (3) required fields are provided
  if [ -z "${INPUT_GITHUB_TOKEN}" ]
  then
    if [ -z "${INPUT_GITHUB_APP_ID}" ] && [ -z "${INPUT_GITHUB_APP_INSTALLATION_ID}" ] && [ -z "${INPUT_GITHUB_APP_PRIVATE_KEY}" ]
    then
      echo "Error: Github token or App information is required."
      echo "The token requires at least Actions permissions."
      usage_docs
      exit 1
    else
      get_app_token
      using_github_app=true
    fi
  else
    token=${INPUT_GITHUB_TOKEN}
  fi

  if [ -z "${INPUT_WORKFLOW_FILE_NAME}" ]
  then
    echo "Error: Workflow File Name is required"
    usage_docs
    exit 1
  fi

  client_payload=$(echo '{}' | jq -c)
  if [ "${INPUT_CLIENT_PAYLOAD}" ]
  then
    client_payload=$(echo "${INPUT_CLIENT_PAYLOAD}" | jq -c)
  fi

  ref="main"
  if [ "$INPUT_REF" ]
  then
    ref="${INPUT_REF}"
  fi
}

# this doesn't appear to be used?
lets_wait() {
  echo "Sleeping for ${wait_interval} seconds"
  sleep "$wait_interval"
}

api() {
  echo "API DEBUG: TOKEN = $token" >> debug.txt
  path=$1; shift
  if response=$(curl --fail-with-body -sSL \
      "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/$path" \
      -H "Authorization: Bearer ${token}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -H 'Content-Type: application/json' \
      "$@")
  then
    echo "$response"
  else
    echo >&2 "api failed:"
    echo >&2 "path: $path"
    echo >&2 "response: $response"
    if [[ "$response" == *'"Server Error"'* ]]; then 
      echo "Server error - trying again"
    else
      exit 1
    fi
  fi
}

lets_wait() {
  local interval=${1:-$wait_interval}
  echo >&2 "Sleeping for $interval seconds"
  sleep "$interval"

  if [ "$using_github_app" = true ]; then
    # lets see if we are close to needing a new token (within 5 mins+$wait_interval)
    current_time=$(date +%s)
    expiration_time=$(date -d"$app_token_expiration" +%s)

    # Add 5 minutes (300 seconds) and the wait_interval to the current time
    current_time_plus_interval=$((current_time + 1 + wait_interval))

    if [ "$current_time_plus_interval" -ge "$expiration_time" ]; then
      echo "  - Current time is within 5 minutes + wait_interval of app_token_expiration - we need to get a new app token" >&2
      get_app_token >&2
      echo "  - new app token retrieved, carrying on" >&2
    fi
  fi
}

# Return the ids of the most recent workflow runs, optionally filtered by user
get_workflow_runs() {
  since=${1:?}

  query="event=workflow_dispatch&created=>=$since${INPUT_GITHUB_USER+&actor=}${INPUT_GITHUB_USER}&per_page=100"

  echo "Getting workflow runs using query: ${query}" >&2

  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/runs?${query}" |
  jq -r '.workflow_runs[].id' |
  sort # Sort to ensure repeatable order, and lexicographically for compatibility with join
}

trigger_workflow() {
  START_TIME=$(date +%s)
  SINCE=$(date -u -Iseconds -d "@$((START_TIME - 120))") # Two minutes ago, to overcome clock skew

  OLD_RUNS=$(get_workflow_runs "$SINCE")

  echo >&2 "Triggering workflow:"
  echo >&2 "  workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches"
  echo >&2 "  {\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches" \
    --data "{\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  NEW_RUNS=$OLD_RUNS
  while [ "$NEW_RUNS" = "$OLD_RUNS" ]
  do
    lets_wait
    NEW_RUNS=$(get_workflow_runs "$SINCE")
  done

  # Return new run ids
  join -v2 <(echo "$OLD_RUNS") <(echo "$NEW_RUNS")
}

comment_downstream_link() {
  # TODO: needs curl --version > 7.76.0
  if response=$(curl --fail-with-body -sSL -X POST \
      "${INPUT_COMMENT_DOWNSTREAM_URL}" \
      -H "Authorization: Bearer ${INPUT_COMMENT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -d "{\"body\": \"Running downstream job at $1\"}")
  then
    echo "$response"
  else
    echo >&2 "failed to comment to ${INPUT_COMMENT_DOWNSTREAM_URL}:"
  fi
}

wait_for_workflow_to_finish() {
  last_workflow_id=${1:?}
  last_workflow_url="${GITHUB_SERVER_URL}/${INPUT_OWNER}/${INPUT_REPO}/actions/runs/${last_workflow_id}"

  echo "Waiting for workflow to finish:"
  echo "The workflow id is [${last_workflow_id}]."
  echo "The workflow logs can be found at ${last_workflow_url}"
  echo "workflow_id=${last_workflow_id}" >> $GITHUB_OUTPUT
  echo "workflow_url=${last_workflow_url}" >> $GITHUB_OUTPUT
  echo ""

  if [ -n "${INPUT_COMMENT_DOWNSTREAM_URL}" ]; then
    comment_downstream_link ${last_workflow_url}
  fi

  conclusion=null
  status=

  while [[ "${conclusion}" == "null" && "${status}" != "completed" ]]
  do
    lets_wait

    workflow=$(api "runs/$last_workflow_id")
    conclusion=$(echo "${workflow}" | jq -r '.conclusion')
    status=$(echo "${workflow}" | jq -r '.status')

    echo "Checking conclusion [${conclusion}]"
    echo "Checking status [${status}]"
    echo "conclusion=${conclusion}" >> $GITHUB_OUTPUT
  done

  if [[ "${conclusion}" == "success" && "${status}" == "completed" ]]
  then
    echo "Yes, success"
  else
    # Alternative "failure"
    echo "Conclusion is not success, it's [${conclusion}]."

    if [ "${propagate_failure}" = true ]
    then
      echo "Propagating failure to upstream job"
      exit 1
    fi
  fi
}

get_app_token() {
  base64key=$(echo -n "$INPUT_GITHUB_APP_PRIVATE_KEY" | base64)
  echo " - getting app token"
  app_token_info=$(gh token generate --app-id "${INPUT_GITHUB_APP_ID}" --installation-id "${INPUT_GITHUB_APP_INSTALLATION_ID}" --base64-key "${base64key}")
  token=$(echo "${app_token_info}" | jq -r '.token')
  app_token_expiration=$(echo "${app_token_info}" | jq -r '.expires_at')
  echo " - app token retrieved"
  echo " - app_token_expiration=${app_token_expiration}"
}

main() {
  validate_args

  if [ "${trigger_workflow}" = true ]
  then
    run_ids=$(trigger_workflow)
  else
    echo "Skipping triggering the workflow."
  fi

  if [ "${wait_workflow}" = true ]
  then
    for run_id in $run_ids
    do
      wait_for_workflow_to_finish "$run_id"
    done
  else
    echo "Skipping waiting for workflow."
  fi
}

main
