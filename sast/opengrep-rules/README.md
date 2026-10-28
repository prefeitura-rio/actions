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

## Rules

| Rule id | Sev | Detects |
|---|---|---|
| `apex-hardcoded-webhook-secret` | ERROR | hardcoded Discord/Slack/Teams webhook token |
| `apex-callout-endpoint-from-user-input` | ERROR | SSRF: callout endpoint taken from caller input |
| `apex-dynamic-callout-endpoint-review` | INFO | dynamic (non-literal) callout endpoint |
| `apex-soql-injection-concatenation` | ERROR | SOQL/SOSL built by string concatenation |
| `apex-test-seealldata-true` | WARNING | `@isTest(SeeAllData=true)` |
| `apex-debug-log-pii` | WARNING | PII / full request serialized into `System.debug` |
| `apex-insecure-http-callout` | WARNING | cleartext `http://` callout |
| `apex-messaging-consent-enforcement-disabled` | WARNING | `isEnforceMessagingChannelConsent=false` |
| `apex-content-visible-to-external-users` | INFO | `IsVisibleByExternalUsers=true` |
| `mule-cleartext-http-port-80` | WARNING | backend on port 80 / `protocol: HTTP` |
| `mule-prod-config-points-to-dev-host` | ERROR | prod config pointing at a `-dev` host |
| `mule-plaintext-secret-in-config` | WARNING | plaintext secret (not `![...]` / `${...}`) |
| `mule-error-detail-exposed-to-caller` | WARNING | `error.description/…` returned to the caller |
| `mule-raw-payload-in-error-response` | WARNING | `#[payload]` echoed on an error response |
| `mule-pii-payload-logging` | WARNING | logger prints the full `#[payload]` |
| `ci-unpinned-latest-install` | WARNING | `@latest` dependency install in a pipeline |
| `ci-secret-on-command-line` | WARNING | secret passed as `-D…=$VAR` / `…=$VAR` |
| `sf-permset-dangerous-system-permission` | WARNING | ModifyAllData/ViewAllData/AuthorApex/ModifyMetadata in a permission set |
| `sf-object-owd-public-readwrite` | INFO | object OWD `ReadWrite` (review objects holding PII) |
| `sf-custom-metadata-secret-in-plaintext` | WARNING | token/secret stored in a `__mdt` Text field |
| `sf-flow-system-mode-without-sharing` | WARNING | flow `SystemModeWithoutSharing` (IDOR risk) |
| `sf-remote-site-protocol-security-disabled` | ERROR | remote site `disableProtocolSecurity=true` |
| `sf-named-credential-no-authentication` | WARNING | Anonymous / NoAuthentication named credential |
| `sf-named-credential-merge-fields-enabled` | WARNING | `allowMergeFieldsInBody/Header=true` |
| `sfmc-untrusted-ephemeral-endpoint` | ERROR | journey/asset → trycloudflare/ngrok/webhook.site/localhost |
| `sfmc-custom-activity-jwt-disabled` | WARNING | custom activity with `useJwt:false` |

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
