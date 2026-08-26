#!/usr/bin/env bash
# GitHub Actions runs shell: bash steps under "bash --noprofile --norc -eo pipefail";
# replicate that here since a nested "bash script.sh" invocation does not inherit it.
set -eo pipefail

# Import sonarqube, opengrep and checkov to defectdojo
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
    # sonarqube
    # DefectDojo's "SonarQube Scan detailed" parser reads the REST API JSON
    # (top-level "paging" + "components"), i.e. the /api/issues/search payload.
    # We build it here and drop external_* rules (the grype/opengrep SARIF
    # imports) so they are not duplicated against their direct DD imports.
    if [ "$SONAR_TOKEN" != "" ] && [ "$SONAR_HOST_URL" != "" ]; then
        rm -f sonar_page_*.json sonar-issues.json
        p=1
        while :; do
            curl -s -u "$SONAR_TOKEN:" \
                "$SONAR_HOST_URL/api/issues/search?components=$PROJECT_KEY&${BRANCH_KEY}=${BRANCH_VALUE}&issueStatuses=OPEN&types=VULNERABILITY&additionalFields=_all&ps=500&p=$p" \
                >"sonar_page_$p.json"
            TOTAL=$(jq '.paging.total // .total // 0' "sonar_page_$p.json")
            PS=$(jq '.paging.pageSize // 500' "sonar_page_$p.json")
            [ $((p * PS)) -ge "$TOTAL" ] && break
            p=$((p + 1))
            [ "$p" -gt 20 ] && break # SonarQube caps issue search at 10000
        done
        jq -s '{
      total: (.[0].paging.total // .[0].total // 0),
      paging: (.[0].paging // {total: (.[0].total // 0)}),
      components: (map(.components // []) | add | unique_by(.key)),
      rules: (map(.rules // []) | add | unique_by(.key)),
      issues: (map(.issues // []) | add
                | map(select((.rule // "") | startswith("external_") | not)))
    }' sonar_page_*.json >sonar-issues.json
        rm -f sonar_page_*.json
        echo "SonarQube native issues to upload (external_* excluded): $(jq '.issues | length' sonar-issues.json)"
        RESPONSE=$(curl -s -X POST "$DD_URL/api/v2/reimport-scan/" \
            -H "Authorization: Token $DD_API_TOKEN" \
            -H "Content-Type: multipart/form-data" \
            -F "active=true" \
            -F "verified=true" \
            -F "scan_type=SonarQube Scan detailed" \
            -F "product_name=$PRODUCT_NAME" \
            -F "engagement_name=$ENGAGEMENT_NAME" \
            -F "file=@sonar-issues.json" \
            -F "$PARAM_TYPE" \
            -F "auto_create_context=true" \
            -F "close_old_findings=true")
        if echo "$RESPONSE" | grep -q '"test":'; then
            echo "Sonarqube scan reimported"
        else
            echo "Error reimporting sonarqube to dojo:"
            echo "$RESPONSE"
        fi
    else
        echo "::warning title=SAST::Skipping SonarQube DefectDojo upload: SONAR_TOKEN/SONAR_HOST_URL not set"
    fi
fi
MAX_RESULTS=200
if [ "$SONAR_TOKEN" != "" ] && [ "$SONAR_HOST_URL" != "" ]; then
    for _ in {1..6}; do
        COUNT=$(curl -s -u "$SONAR_TOKEN": \
            "$SONAR_HOST_URL/api/issues/search?components=$PROJECT_KEY&${BRANCH_KEY}=${BRANCH_VALUE}&issueStatuses=OPEN&ps=1" |
            jq '.total')

        [ "$COUNT" -ge 0 ] && break
        sleep 10
    done

    RESPONSE=$(curl -s -u "$SONAR_TOKEN": \
        "$SONAR_HOST_URL/api/issues/search?components=$PROJECT_KEY&${BRANCH_KEY}=${BRANCH_VALUE}&issueStatuses=OPEN&types=VULNERABILITY&ps=$MAX_RESULTS")

    TOTAL=$(echo "$RESPONSE" | jq '.total')

    if [ "$TOTAL" -eq 0 ]; then
        echo "No new security issues" >>"$GITHUB_STEP_SUMMARY"
        echo "" >>"$GITHUB_STEP_SUMMARY"
    fi

    TOTAL_CRITICAL=$(echo "$RESPONSE" | jq -r '.issues | map(select(.severity == "CRITICAL")) | length')
    TOTAL_HIGH=$(echo "$RESPONSE" | jq -r '.issues | map(select(.severity == "HIGH")) | length')
    TOTAL_MEDIUM=$(echo "$RESPONSE" | jq -r '.issues | map(select(.severity == "MEDIUM")) | length')

    SONAR_ISSUES=$(echo "$RESPONSE" | jq '
      .issues
      | unique_by(.key)
      # external_* rules are SARIF findings imported from grype/opengrep/
      # checkov (see sonar.sarifReportPaths above); they are shown in
      # their own dedicated sections below so excluding them here avoids
      # listing the same finding twice.
      | map(select((.rule // "") | startswith("external_") | not ))
  ')

    if [ "$(echo "$SONAR_ISSUES" | jq 'length')" -gt 0 ]; then
        SONAR_ROWS=$(echo "$SONAR_ISSUES" | jq -r '
      .[] |
      "| [" + .message + "]('"$SONAR_HOST_URL_PUBLIC"'/project/issues?id='"$PROJECT_KEY"'&open=" + .key + ") | " +
      (.component | split(":")[-1]) + ":"+((.line // "please check output") | tostring)+" | " +
      .rule + " |" + .severity +" |"
      ')
        {
            echo "### Sonar Security Findings"
            echo ""
            echo "| Issue | File | Rule | Severity |"
            echo "|------|------|------|-----------|"
            echo "$SONAR_ROWS"
            echo ""
        } >>"$GITHUB_STEP_SUMMARY"
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

# opengrep results are surfaced separately from the generic Sonar
# Security Findings table above (its external_* rule is excluded
# there) so each finding is shown exactly once.
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

if [ "$SONAR_TOKEN" != "" ] && [ "$SONAR_HOST_URL" != "" ]; then
    HOTSPOTS=$(curl -s -u "$SONAR_TOKEN": \
        "$SONAR_HOST_URL/api/hotspots/search?project=$PROJECT_KEY&${BRANCH_KEY}=${BRANCH_VALUE}&status=TO_REVIEW&ps=$MAX_RESULTS")
    HOTSPOT_COUNT=$(echo "$HOTSPOTS" | jq '.paging.total')

    HOTSPOTS=$(echo "$HOTSPOTS" | jq '.hotspots')

    if [ "$HOTSPOT_COUNT" -gt 0 ]; then
        HOTSPOT_ROWS=$(echo "$HOTSPOTS" | jq -r \
            --arg host "$SONAR_HOST_URL_PUBLIC" \
            --arg project "$PROJECT_KEY" \
            --arg branch_key "$BRANCH_KEY" \
            --arg branch_value "$BRANCH_VALUE" '
      .[] |
      "| [" + .message + "](" +
          $host + "/security_hotspots?hotspots=" + .key +
          "&"+$branch_key+"=" + $branch_value + "&id=" + $project +
      ") | " +
      (.component | split(":")[-1]) + ":"+((.line // "-") | tostring)+" | " +
      .securityCategory + " | "
      ')
        {
            echo "### Security Hotspots (Review Required)"
            echo "| Hotspot | File | Category |"
            echo "|---------|------|----------|"
            echo "$HOTSPOT_ROWS"
            echo ""
        } >>"$GITHUB_STEP_SUMMARY"
    else
        {
            echo "### Security Hotspots"
            echo "No new security hotspots"
            echo ""
        } >>"$GITHUB_STEP_SUMMARY"
    fi

    echo "[View all new security issues in SonarQube]($SONAR_HOST_URL_PUBLIC/project/issues?id=$PROJECT_KEY&${BRANCH_KEY}=${BRANCH_VALUE}&types=VULNERABILITY&sinceLeakPeriod=true)" >>"$GITHUB_STEP_SUMMARY"
    if [ "$BREAK_ON" == "CRITICAL" ] && [ "$TOTAL_CRITICAL" -gt 0 ]; then
        echo "::error title=SAST::Quality gate met CRITICAL"
        exit 1
    elif [ "$BREAK_ON" == "HIGH" ] && [ "$TOTAL_CRITICAL" -gt 0 ]; then
        echo "::error title=SAST::Quality gate met HIGH"
        exit 1
    elif [ "$BREAK_ON" == "MEDIUM" ] && { [ "$TOTAL_CRITICAL" -gt 0 ] || [ "$TOTAL_MEDIUM" -gt 0 ]; }; then
        echo "::error title=SAST::Quality gate met MEDIUM"
        exit 1
    elif [ "$BREAK_ON" == "LOW" ] && { [ "$TOTAL_CRITICAL" -gt 0 ] || [ "$TOTAL_HIGH" -gt 0 ] || [ "$TOTAL_MEDIUM" -gt 0 ]; }; then
        echo "::error title=SAST::Quality gate met LOW"
        exit 1
    fi
fi
