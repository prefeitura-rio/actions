#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail";
# replicate that here since a nested "bash script.sh" invocation does not inherit it.
set -eo pipefail

# Import opengrep and checkov to defectdojo (grype goes in run-vulnerability-scan.sh)
if [ "$DD_API_TOKEN" != "" ] && [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
    PRODUCT_INFO=$(curl -s -X GET "$DD_URL/api/v2/products/?name=${PRODUCT_NAME}" \
        -H "Authorization: Token $DD_API_TOKEN")
    PRODUCT_INFO=$(echo -n "$PRODUCT_INFO" | tr -d '\000-\037')
    COUNT=$(echo "$PRODUCT_INFO" | jq '.count')
    if [ "$COUNT" -gt 0 ]; then
        PRODUCT_TYPE_ID=$(echo "$PRODUCT_INFO" | jq '.results[0].prod_type')
        PARAM_TYPE="product_type=$PRODUCT_TYPE_ID"
    else
        echo "Creating product on defectdojo"
        PARAM_TYPE="product_type_name=Uncategorized"
    fi
    # opengrep
    RESPONSE=$(curl -s -X POST "$DD_URL/api/v2/reimport-scan/" \
        -H "Authorization: Token $DD_API_TOKEN" \
        -H "Content-Type: multipart/form-data" \
        -F "active=true" \
        -F "verified=true" \
        -F "scan_type=Semgrep JSON Report" \
        -F "product_name=$PRODUCT_NAME" \
        -F "engagement_name=$ENGAGEMENT_NAME" \
        -F "file=@opengrep-report.json" \
        -F "$PARAM_TYPE" \
        -F "auto_create_context=true" \
        -F "close_old_findings=true")
    if echo "$RESPONSE" | grep -q '"test":'; then
        echo "Opengrep scan reimported"
    else
        echo "Error reimporting opengrep to dojo:"
        echo "$RESPONSE"
    fi
    # checkov
    if [ "$ENABLE_CHECKOV" = "true" ] && [ -f checkov-report.json ]; then
        RESPONSE=$(curl -s -X POST "$DD_URL/api/v2/reimport-scan/" \
            -H "Authorization: Token $DD_API_TOKEN" \
            -H "Content-Type: multipart/form-data" \
            -F "active=true" \
            -F "verified=true" \
            -F "scan_type=Checkov Scan" \
            -F "product_name=$PRODUCT_NAME" \
            -F "engagement_name=$ENGAGEMENT_NAME" \
            -F "file=@checkov-report.json" \
            -F "$PARAM_TYPE" \
            -F "auto_create_context=true" \
            -F "close_old_findings=true")
        if echo "$RESPONSE" | grep -q '"test":'; then
            echo "Checkov scan reimported"
        else
            echo "Error reimporting checkov to dojo:"
            echo "$RESPONSE"
        fi
    fi
fi

GRYPE_ISSUES=$(cat grype-results.sarif | jq '.runs[0].tool.driver.rules')
if [[ -n "$GRYPE_ISSUES" && "$GRYPE_ISSUES" != "null" && "$GRYPE_ISSUES" != "[]" && "$(echo "$GRYPE_ISSUES" | jq 'length')" -gt 0 ]]; then
    GRYPE_ROWS=$(echo "$GRYPE_ISSUES" | jq -r '
    def map_severity:
    {
        "critical": "CRITICAL",
        "high": "HIGH",
        "medium": "MEDIUM",
        "low": "LOW"
    }[.] // .;

    .[] |
    # Extração segura dos dados via Regex
    (.help.text | capture("Severity: (?<s>[^\\n]+)").s) as $raw_sev |
    (.help.text | capture("Link: \\[[^\\]]+\\]\\((?<url>[^\\)]+)\\)").url) as $url |
    (.help.text | capture("Package: (?<p>[^\\n]+)").p) as $pkg |
    (.help.text | capture("Version: (?<v>[^\\n]+)").v) as $ver |
    (.help.text | capture("Fix Version: (?<f>[^\\n]+)").f) as $fix |
    (.help.text | capture("Location: (?<l>[^\\n]+)").l) as $loc |
    (.properties["security-severity"] // "N/A") as $cvss |
    
    # Formatação da Severidade
    (($raw_sev | map_severity) + " (" + ($cvss|tostring) + ")") as $final_sev |

    # Montagem da linha na ordem correta do cabeçalho
    "| [" + .id + "](" + $url + ") | " + 
    $pkg + " | " + 
    $ver + " | " + 
    $fix + " | " + 
    $final_sev + " | " + 
    $loc + " |"
    ')
    {
        echo "### Dependency Vulnerabilities"
        echo ""
        echo "| Advisory | Package | Installed | Fixed | Severity | File |"
        echo "|:---|:---|:---|:---|:---|:---|"
        echo "$GRYPE_ROWS"
        echo ""
    } >>"$GITHUB_STEP_SUMMARY"
fi

OPENGREP_ISSUES=$(jq -c '.results // []' opengrep-report.json)
if [ "$(echo "$OPENGREP_ISSUES" | jq 'length')" -gt 0 ]; then
    OPENGREP_ROWS=$(echo "$OPENGREP_ISSUES" | jq -r '
    def map_severity:
    {
        "ERROR": "HIGH",
        "WARNING": "MEDIUM",
        "INFO": "LOW"
    }[.] // .;

    .[] |
    (.extra.metadata.shortlink // "") as $link |
    (if $link != "" then "[" + .check_id + "](" + $link + ")" else .check_id end) as $rule |
    (.extra.message | gsub("\\|"; "\\|")) as $msg |
    "| " + $msg + " | " +
    .path + ":" + (.start.line | tostring) + " | " +
    $rule + " | " +
    (.extra.severity | map_severity) + " |"
    ')
    {
        echo "### Static Analysis (opengrep)"
        echo ""
        echo "| Issue | File | Rule | Severity |"
        echo "|:---|:---|:---|:---|"
        echo "$OPENGREP_ROWS"
        echo ""
    } >>"$GITHUB_STEP_SUMMARY"
fi

# checkov results are a single object, or a list of objects when several
# frameworks (terraform, dockerfile, github_actions, ...) match.
if [ "$ENABLE_CHECKOV" = "true" ] && [ -f checkov-report.json ]; then
    CHECKOV_FAILED=$(jq -c '
    [ (if type == "array" then .[] else . end)
      | (.check_type // "iac") as $fw
      | (.results.failed_checks // [])[]
      | . + { check_type: $fw } ]
  ' checkov-report.json)

    if [ "$(echo "$CHECKOV_FAILED" | jq 'length')" -gt 0 ]; then
        CHECKOV_ROWS=$(echo "$CHECKOV_FAILED" | jq -r '
      .[] |
      (if .guideline then "[" + .check_id + "](" + .guideline + ")" else .check_id end) as $check |
      "| " + $check + ": " + (.check_name // "") + " | " +
      (.resource // "-") + " | " +
      (.file_path // "-") + ":" + ((.file_line_range[0] // "-") | tostring) + " | " +
      .check_type + " |"
      ')
        {
            echo "### Infrastructure as Code (checkov)"
            echo ""
            echo "| Check | Resource | File | Framework |"
            echo "|:---|:---|:---|:---|"
            echo "$CHECKOV_ROWS"
            echo ""
        } >>"$GITHUB_STEP_SUMMARY"
    else
        {
            echo "### Infrastructure as Code (checkov)"
            echo "No IaC misconfigurations found"
            echo ""
        } >>"$GITHUB_STEP_SUMMARY"
    fi
fi

# break_on: fail when grype or opengrep report a finding at or above that
# severity (opengrep: ERROR=HIGH, WARNING=MEDIUM, INFO=LOW). checkov is
# report-only. Any other value, such as the action's default "-", disables
# the gate.
case "$BREAK_ON" in
CRITICAL) THRESHOLD=4 ;;
HIGH) THRESHOLD=3 ;;
MEDIUM) THRESHOLD=2 ;;
LOW) THRESHOLD=1 ;;
*) THRESHOLD=0 ;;
esac
if [ "$THRESHOLD" -gt 0 ]; then
    GRYPE_BREAKING=$(jq -s --argjson t "$THRESHOLD" '
    [ .[] | .runs[]?.tool.driver.rules[]?
      | ([(.help.text // "") | capture("Severity: (?<s>[^\\n]+)") | .s][0] // "" | ascii_downcase) as $s
      | select(({"critical": 4, "high": 3, "medium": 2, "low": 1}[$s] // 0) >= $t) ]
    | length
  ' grype-results.sarif)
    OPENGREP_BREAKING=$(jq -s --argjson t "$THRESHOLD" '
    [ .[] | .results[]?
      | select(({"ERROR": 3, "WARNING": 2, "INFO": 1}[.extra.severity] // 0) >= $t) ]
    | length
  ' opengrep-report.json)
    if [ "$GRYPE_BREAKING" -gt 0 ] || [ "$OPENGREP_BREAKING" -gt 0 ]; then
        echo "::error title=SAST::Quality gate met $BREAK_ON: $GRYPE_BREAKING dependency vulnerabilities and $OPENGREP_BREAKING opengrep findings at or above $BREAK_ON"
        exit 1
    fi
fi
