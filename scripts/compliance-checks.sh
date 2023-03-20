#!/usr/bin/env bash

source ./scripts/one-pipeline-helper.sh
source "${ONE_PIPELINE_PATH}/internal/tools/logging"
source "${ONE_PIPELINE_PATH}/tools/get_repo_params"
#source "${COMMONS_PATH}/cra/run-cra-bom.sh"
# source "./cc/run-cra-vulnerability-scan.sh"
# source "${COMMONS_PATH}/cra/run-cra-deploy-analysis.sh"
source "./auto-remediation.sh"

#
# SETUP
#
# Update the ibmcloud cli cra plugin to get the latest version
ibmcloud plugin update cra --force

# Set up Devops Insights toolchain
# Use the default Toolchain ID if needed
export TOOLCHAIN_ID
TOOLCHAIN_ID="$(get_env DOI_TOOLCHAIN_ID "")"
if [ -z "$TOOLCHAIN_ID" ]; then
  TOOLCHAIN_ID="$(get_env TOOLCHAIN_ID)"
fi

# Create a dry-run k8s secret of type docker-registry to obtain
# the pull secrets for the base image used in the dockerfile.
# This is optional, but sometimes useful, for example when using
# images from a private registry.
BASEIMAGE_AUTH_USER="$(get_env baseimage-auth-user "")"
BASEIMAGE_AUTH_HOST="$(get_env baseimage-auth-host "")"
BASEIMAGE_AUTH_PASSWORD="$(get_env baseimage-auth-password "")"
if [ -n "$BASEIMAGE_AUTH_PASSWORD" ] &&
  [ -n "$BASEIMAGE_AUTH_USER" ] &&
  [ -n "$BASEIMAGE_AUTH_HOST" ]; then
  debug "Adding pull secrets to access base image registry $BASEIMAGE_AUTH_HOST"
  mkdir -p /root/.docker
  kubectl create secret --dry-run=client --output=json \
    docker-registry registry-dockerconfig-secret \
    --docker-username="$BASEIMAGE_AUTH_USER" \
    --docker-password="$BASEIMAGE_AUTH_PASSWORD" \
    --docker-server="$BASEIMAGE_AUTH_HOST" \
    --docker-email="$(get_env baseimage-auth-email "")" |
    jq -r '.data[".dockerconfigjson"]' | base64 -d >/root/.docker/config.json
fi

# Set up collected statuses for legacy v1 evidence collection.
# Note that v2 evidence collection is done by the scripts used
# from commons
export detect_secrets_status=0
export cra_bom_status=0
export cra_va_status=0
export cra_cis_status=0
export branch_protection_status=0
export cra_tf_status=0
export tfsec_status=0
export checkov_status=0

set_cra_bom_status() {
  #
  # Aggregate results of CRA BOM runs
  #
  if [ "$cra_bom_status" == 0 ]; then
    CRA_BOM_CHECK_RESULTS_STATUS="success"
  else
    CRA_BOM_CHECK_RESULTS_STATUS="failure"
  fi
  #
  # Set commit status for CRA BOM if we're in a PR pipeline
  #
  if [ "$(get_env pipeline_namespace)" == "pr" ]; then
    set-commit-status \
      --repository "$1" \
      --commit-sha "$2" \
      --state "${CRA_BOM_CHECK_RESULTS_STATUS}" \
      --description "BOM check finished running." \
      --context "tekton/code-bom-check" \
      --task-name "$(get_env BOM_CHECK_TASK_NAME)" \
      --step-name "$(get_env BOM_CHECK_STEP_NAME)"
  fi
  #
  # Save aggregated result for evidence v1 (legacy) for
  # CRA BOM
  #
  put_data result bom-check "$CRA_BOM_CHECK_RESULTS_STATUS"
  set_env CRA_BOM_CHECK_RESULTS_STATUS "$CRA_BOM_CHECK_RESULTS_STATUS"
}

set_cra_va_status() {
  #
  # Aggregate results of CRA VA runs
  #
  if [ "$cra_va_status" == 0 ]; then
    CRA_VULNERABILITY_RESULTS_STATUS="success"
  else
    CRA_VULNERABILITY_RESULTS_STATUS="failure"
  fi
  #
  # Set commit status for CRA VA if we're in a PR pipeline
  #
  if [ "$(get_env pipeline_namespace)" == "pr" ]; then
    set-commit-status \
      --repository "$1" \
      --commit-sha "$2" \
      --state "${CRA_VULNERABILITY_RESULTS_STATUS}" \
      --description "Vulnerability scan finished running." \
      --context "tekton/code-vulnerability-scan" \
      --task-name "$(get_env CRA_VULNERABILITY_TASK_NAME)" \
      --step-name "$(get_env CRA_VULNERABILITY_STEP_NAME)"
  fi
  #
  # Save aggregated result for evidence v1 (legacy) for
  # CRA VA
  #
  put_data result vulnerability-scan "$CRA_VULNERABILITY_RESULTS_STATUS"
  set_env CRA_VULNERABILITY_RESULTS_STATUS "$CRA_VULNERABILITY_RESULTS_STATUS"
}

set_cra_cis_status() {
  #
  # Aggregate results of CRA CIS runs
  #
  if [ "$cra_cis_status" == 0 ]; then
    CIS_CHECK_VULNERABILITY_RESULTS_STATUS="success"
  else
    CIS_CHECK_VULNERABILITY_RESULTS_STATUS="failure"
  fi
  #
  # Set commit status for CRA CIS if we're in a PR pipeline
  #
  if [ "$(get_env pipeline_namespace)" == "pr" ]; then
    set-commit-status \
      --repository "$1" \
      --commit-sha "$2" \
      --state "${CIS_CHECK_VULNERABILITY_RESULTS_STATUS}" \
      --description "CIS check finished running." \
      --context "tekton/code-cis-check" \
      --task-name "$(get_env CIS_CHECK_TASK_NAME)" \
      --step-name "$(get_env CIS_CHECK_STEP_NAME)"
  fi
  #
  # Save aggregated result for evidence v1 (legacy) for
  # CRA CIS
  #
  put_data result cis-check "$CIS_CHECK_VULNERABILITY_RESULTS_STATUS"
  set_env CIS_CHECK_VULNERABILITY_RESULTS_STATUS "$CIS_CHECK_VULNERABILITY_RESULTS_STATUS"
}

#
# RUN SCANS
#
# Iterate over repos that were registered to the pipeline
# by the save_repo of the pipelinectl tool.
while read -r repo; do
  path="$(load_repo "${repo}" path)"
  url="$(load_repo "${repo}" url)"
  commit_sha="$(load_repo "${repo}" commit)"

  if [[ "$(get_env pipeline_namespace)" == *"cc"* ]]; then
    set_env doi-buildnumber "$(load_repo "${repo}" buildnumber)"
  fi

  # Branch protection checks should not be running in CC pipelines
  if [ "$(get_env pipeline_namespace "")" != "cc" ]; then
    # check branch protection settings and required checks for a commit
    # branch should be the PR base branch if we're in a PR pipeline
    if [ -n "$(get_env HEAD_SHA "")" ] && [ -n "$(get_env BASE_BRANCH "")" ]; then
      commit="$(get_env HEAD_SHA)"
      branch="$(get_env BASE_BRANCH)"
    else
      commit="$(load_repo "${repo}" commit)"
      branch="$(load_repo "${repo}" branch)"
    fi

  fi

  # run cra bom discovery and save bom to a file
  bom_json="$WORKSPACE/${repo}_cra_bom.json"
  run-cra-bom "${url}" "${path}" "${repo}" "${bom_json}"
  exit_code=$?
  cra_bom_status=$((cra_bom_status + exit_code))
  set_cra_bom_status "${url}" "${commit_sha}"

  # run cra vulnerability scan using the BOM from "run_cra_bom"
#   run-cra-vulnerability-scan "${url}" "${path}" "${repo}" "$(get_env report_name "${bom_json}")"
#   exit_code=$?
#   echo "Exit code of the scan - ${exit_code}"
  run-cra-auto-remediation "${url}" "${path}" "${repo}" "$(get_env report_name "${bom_json}")"
  cra_va_status=$((cra_va_status + exit_code))
  set_cra_va_status "${url}" "${commit_sha}"

  # run cra deployment analysis
#   run-cra-deploy-analysis "${url}" "${path}" "${repo}"
#   exit_code=$?
#   cra_cis_status=$((cra_cis_status + exit_code))
#   set_cra_cis_status "${url}" "${commit_sha}"

done < <(list_repos)

if [ "${branch_protection_status}" != "0" ] || [ "${detect_secrets_status}" != "0" ] || [ "${cra_bom_status}" != "0" ] || \
   [ "${cra_va_status}" != "0" ] || [ "${cra_cis_status}" != "0" ] || \
   [ "${cra_tf_status}" != "0" ] || [ "${tfsec_status}" != "0" ] || [ "${checkov_status}" != 0 ]; then
    exit 1
fi

exit 1