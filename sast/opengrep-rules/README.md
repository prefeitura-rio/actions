# Custom Opengrep rules

Rules in this directory are auto-loaded by `scripts/run-opengrep.sh`
(`opengrep scan . --config p/default --config "$GITHUB_ACTION_PATH/opengrep-rules/"`),
so adding a `*.yaml` here is enough — no `action.yml` change required.
Findings are converted to SARIF, filtered for in-source `NOSONAR` suppressions,
and fed to SonarQube / DefectDojo.

## Layout

| Dir | Target | Notes |
|---|---|---|
| `python/` | `*.py` | native parser |
| `apex/` | `*.cls`, `*.trigger` | Salesforce Apex — **generic + `pattern-regex`** (Opengrep has no Apex parser) |
| `mule/` | Mule `*.xml` flows, `config-*.yaml`, `credentials-*.yaml` | generic + regex |
| `ci/` | `.gitlab-ci.yml`, `.github/workflows/*.yml` | generic + regex |
| `salesforce-metadata/` | `*.permissionset-meta.xml`, `*.object-meta.xml`, `*.md-meta.xml`, `*.flow-meta.xml`, `*.namedCredential-meta.xml`, `*.remoteSite-meta.xml` | permission/sharing/credential posture; generic + regex |
| `sfmc/` | SFMC `*.journey-meta.json`, `*.asset-asset-meta.*` | untrusted endpoints / JWT-disabled activities; generic + regex |

Because Apex/Mule-XML have no Opengrep parser, those rules use
`languages: [generic]` + `pattern-regex` scoped with `paths.include`. Keep the
`paths.include` globs tight so generic regex does not bleed into unrelated files.

## Rules and the findings they codify

Derived from the manual review in the scanned repo's `SECURITY_REVIEW.md`.

| Rule id | Sev | Finding |
|---|---|---|
| `apex-hardcoded-webhook-secret` | ERROR | H-01 hardcoded Discord/Slack webhook token |
| `apex-callout-endpoint-from-user-input` | ERROR | M-01 SSRF: callout endpoint from caller input |
| `apex-dynamic-callout-endpoint-review` | INFO | M-01 dynamic (non-literal) callout endpoint |
| `apex-soql-injection-concatenation` | ERROR | SOQL/SOSL built by string concatenation |
| `apex-test-seealldata-true` | WARNING | L-01 `@isTest(SeeAllData=true)` |
| `apex-debug-log-pii` | WARNING | L-04 PII/full-request in `System.debug` |
| `apex-insecure-http-callout` | WARNING | cleartext `http://` callout |
| `mule-cleartext-http-port-80` | WARNING | H-02 port 80 / `protocol: HTTP` backend |
| `mule-prod-config-points-to-dev-host` | ERROR | M-08 prod config points to a `-dev` host |
| `mule-plaintext-secret-in-config` | WARNING | M-07 plaintext secret (not `![...]`/`${...}`) |
| `mule-error-detail-exposed-to-caller` | WARNING | H-03 `error.description/…` returned to caller |
| `mule-raw-payload-in-error-response` | WARNING | H-03 `#[payload]` echoed on error response |
| `mule-pii-payload-logging` | WARNING | M-05 logger prints `#[payload]` |
| `ci-unpinned-latest-install` | WARNING | H-05 `@latest` install in a pipeline |
| `ci-secret-on-command-line` | WARNING | M-09 secret passed as `-D…=$VAR` / `…=$VAR` |
| `apex-messaging-consent-enforcement-disabled` | WARNING | F-07 `isEnforceMessagingChannelConsent=false` |
| `apex-content-visible-to-external-users` | INFO | F-11 `IsVisibleByExternalUsers=true` |
| `sf-permset-dangerous-system-permission` | WARNING | C1/C2 ModifyAllData/ViewAllData/AuthorApex in a permset |
| `sf-object-owd-public-readwrite` | INFO | H3/H5 object OWD `ReadWrite` (PII objects) |
| `sf-custom-metadata-secret-in-plaintext` | WARNING | H7/F-08 token/secret in a `__mdt` Text field |
| `sf-flow-system-mode-without-sharing` | WARNING | H6 flow `SystemModeWithoutSharing` (IDOR) |
| `sf-remote-site-protocol-security-disabled` | ERROR | remote site `disableProtocolSecurity=true` |
| `sf-named-credential-no-authentication` | WARNING | M3 Anonymous/NoAuthentication named credential |
| `sf-named-credential-merge-fields-enabled` | WARNING | M4 `allowMergeFieldsInBody/Header=true` |
| `sfmc-untrusted-ephemeral-endpoint` | ERROR | SFMC C1/C2 journey → trycloudflare/ngrok/webhook.site/localhost |
| `sfmc-custom-activity-jwt-disabled` | WARNING | SFMC C1/C2 custom activity `useJwt:false` |

## Conventions

- Messages in pt-BR (matches the existing `python/` rule), lead with the risk.
- Always set `metadata.cwe` (+ `owasp` where it maps) and `confidence`.
- Suppress a specific line in source with a trailing `NOSONAR <rule-id>` comment;
  `run-opengrep.sh` drops in-source suppressions before SARIF upload.

## Local test

```bash
opengrep scan <path-to-repo> --config ./ --json-output=/tmp/og.json
jq -r '.results[].check_id' /tmp/og.json | sort | uniq -c | sort -rn
```
