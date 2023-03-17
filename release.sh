#!/usr/bin/env bash

#
# prepare data for the release step. Here we upload all the metadata to the Inventory Repo.
# If you want to add any information or artifact to the inventory repo then use the "cocoa inventory add command"
#

# shellcheck source=/dev/null
. "${ONE_PIPELINE_PATH}/tools/get_repo_params"

# Check the status of pipeline and then release the artifacts to inventory

ONE_PIPELINE_STATUS=$(get_env one-pipeline-status 0)
if [ -n "$(get_env skip-inventory-update-on-failure "")" ]; then
    if [ $ONE_PIPELINE_STATUS -eq 1 ]; then
          echo "Skipping release stage as some of the pipeline stages are not successfull."
          exit 1
    fi
fi

APP_REPO="$(load_repo app-repo url)"

COMMIT_SHA="$(load_repo app-repo commit)"

APP_ABSOLUTE_SCM_TYPE=$(get_absolute_scm_type "$APP_REPO")

INVENTORY_TOKEN_PATH="./inventory-token"
read -r INVENTORY_REPO_NAME INVENTORY_REPO_OWNER INVENTORY_SCM_TYPE INVENTORY_API_URL < <(get_repo_params "$(get_env INVENTORY_URL)" "$INVENTORY_TOKEN_PATH")
#
# collect common parameters into an array
#
params=(
    --repository-url="${APP_REPO}"
    --commit-sha="${COMMIT_SHA}"
    --version="${COMMIT_SHA}"
    --build-number="${BUILD_NUMBER}"
    --pipeline-run-id="${PIPELINE_RUN_ID}"
    --org="$INVENTORY_REPO_OWNER"
    --repo="$INVENTORY_REPO_NAME"
    --git-provider="$INVENTORY_SCM_TYPE"
    --git-token-path="$INVENTORY_TOKEN_PATH"
    --git-api-url="$INVENTORY_API_URL"
)

#
# add the deployment file as a build artifact to the inventory
#
# APP_TOKEN_PATH="./app-token"
# read -r APP_REPO_NAME APP_REPO_OWNER APP_SCM_TYPE APP_API_URL < <(get_repo_params "$(get_env APP_REPO)" "$APP_TOKEN_PATH")
# token=$(cat $APP_TOKEN_PATH)
