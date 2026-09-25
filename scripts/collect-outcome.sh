#!/usr/bin/env bash
# One answer to "did this run deploy anything, and did it work?", for the notification
# sinks and the deployment record to share.
#
# Every target reports `deployed` in the same shape, so this stays a fold rather than a
# per-target case. A skip is its own status: reporting it as a failure is what makes
# people re-run a fork pull request three times before reading the reason.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SKIP="${SKIP:-false}"
JOB_STATUS="${JOB_STATUS:-success}"

deployed=false
for value in "${DOCS_SITE_DIR:-}" "${S3_DEPLOYED:-}" "${LAMBDA_DEPLOYED:-}" \
             "${TG_DEPLOYED:-}" "${ANSIBLE_DEPLOYED:-}" "${CF_DEPLOYED:-}" \
             "${AZ_DEPLOYED:-}" "${APIM_DEPLOYED:-}"; do
  # The docs target reports a built site path rather than a boolean, because "the site
  # exists" is the only thing it can honestly claim: for github-pages the deploy belongs
  # to the calling workflow.
  [[ -n "$value" && "$value" != "false" ]] && deployed=true
done

# `deployed` is reported, not used to decide the status. A terragrunt run that planned and
# waits for an approval deployed nothing and is not a failure; nor is an Ansible check-mode
# run on a pull request. The adapters fail loudly when something is actually wrong, and that
# is what `job.status` carries.
status=success
if tremvok::is_true "$SKIP"; then
  status=skipped
elif [[ "$JOB_STATUS" != "success" ]]; then
  status=failure
fi

tremvok::set_output deployed "$deployed"
tremvok::set_output status "$status"
tremvok::log "outcome: status=${status} deployed=${deployed}"
