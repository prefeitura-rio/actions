#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail"; this
# step deliberately ran under "set +e" instead (it wants to keep going through wget/jq
# failures and report a manual GET_RESULT_CODE at the end, gated by continue-on-error:
# true on the step), so only pipefail is replicated here, not errexit.
set -o pipefail

# SONAR_TASK_ID is supplied by the step's env: block
# (from steps.sonar_task_id_step.outputs.sonar_task_id).
[ "" == "$SONAR_TASK_ID" ] && echo "Missing Sonar task ID."
[ "" == "${SONAR_TOKEN}" ] && echo "Missing Sonar token."
[ "" != "$SONAR_TASK_ID" ] && [ "" != "${SONAR_TOKEN}" ] && wget -X GET --header="Authorization: Bearer ${SONAR_TOKEN}" -O sonar.status.json "${SONAR_HOST_URL}/api/ce/task?id=$SONAR_TASK_ID"
[ -f sonar.status.json ] && echo "Sonar status: " && cat sonar.status.json && echo
[ -f sonar.status.json ] && SONAR_ANALYSIS_ID=$(cat sonar.status.json | jq '.task.analysisId' | tr -d '"')
echo "SONAR_ANALYSIS_ID=$SONAR_ANALYSIS_ID"
[ "" != "$SONAR_ANALYSIS_ID" ] && [ "" != "${SONAR_TOKEN}" ] && wget -v -X GET --header="Authorization: Bearer ${SONAR_TOKEN}" -O sonar.result.json "${SONAR_HOST_URL}/api/qualitygates/project_status?analysisId=$SONAR_ANALYSIS_ID"
GET_RESULT_CODE=$?
echo "GET_RESULT_CODE=$GET_RESULT_CODE"
[ -f sonar.result.json ] && echo "Sonar result:" && cat sonar.result.json || echo "No Sonar result JSON file created."
# If the output file contains only the returned error message delete it so the evidence creation step won't try to create an evidence out of it.
[ $GET_RESULT_CODE -ne 0 ] && rm sonar.result.json
# return 0 if GET_RESULT_CODE is 0
[ $GET_RESULT_CODE -eq 0 ]
