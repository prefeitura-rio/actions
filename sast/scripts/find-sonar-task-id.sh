#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail";
# replicate that here since a nested "bash script.sh" invocation does not inherit it.
set -eo pipefail

echo "Searching for report-task.txt file..."
REPORT_TASK_FILE=$(find . -name 'report-task.txt' | head -n1)
[ -f "$REPORT_TASK_FILE" ] || echo "repot-task.txt file was not found."
#[ -f "$REPORT_TASK_FILE" ] && echo "report-task.txt content:" && cat "$REPORT_TASK_FILE"
[ -f "$REPORT_TASK_FILE" ] && echo "Sonar report file: $REPORT_TASK_FILE"
[ -f "$REPORT_TASK_FILE" ] && SONAR_TASK_ID=$(grep 'ceTaskId=' "$REPORT_TASK_FILE" | cut -d'=' -f2)
[ "" == "$SONAR_TASK_ID" ] && echo "Sonar task ID was not found."
[ "" != "$SONAR_TASK_ID" ] && echo "Sonar task ID: $SONAR_TASK_ID"
echo "sonar_task_id=$SONAR_TASK_ID" >>"$GITHUB_OUTPUT"
