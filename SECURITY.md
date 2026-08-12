# Security policy

## Supported versions

Only the newest FaceLock release and the current `main` branch receive security fixes.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting flow:

1. Open the repository's **Security** tab.
2. Choose **Advisories**.
3. Select **Report a vulnerability**.

Include the affected version, macOS version, reproduction steps, impact, and a minimal proof of concept. Do not include a real Mac password, face profile, camera image, Keychain export, Apple signing credential, or another person's biometric data.

Please do not post exploitable details in a public issue before a fix is available. General bugs that do not expose security-sensitive behavior can use the normal issue tracker.

## Scope reminder

FaceLock is a portfolio/research demo, not an official macOS authentication mechanism. Known architectural limitations documented in the README—such as password material existing briefly in memory, Accessibility's broad privilege, RGB-only liveness, and macOS potentially rejecting synthetic input—are not by themselves vulnerabilities unless a report demonstrates a new, concrete exploit or unexpected exposure.
