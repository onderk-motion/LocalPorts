# Security Policy

## Supported Versions
Security fixes are applied to the latest version on `main`.

## Reporting a Vulnerability
- Do not open public issues for security vulnerabilities.
- Use GitHub Security Advisories for private disclosure:
  - Repository -> `Security` -> `Report a vulnerability`
- Include:
  - Impacted version/commit
  - Reproduction steps
  - Proof of concept (if possible)
  - Suggested mitigation (optional)

## Response Expectations
- Initial triage target: within 7 days.
- Confirmed issues are patched and released as soon as practical.
- Credits are included in release notes when requested.

## Scope Notes
This project executes user-provided local commands by design. Bugs related to unintended command execution, import safety, or privilege boundaries are in scope and should be reported.
