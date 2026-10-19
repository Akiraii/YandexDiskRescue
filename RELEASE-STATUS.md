# Implementation and verification ledger

## Implemented in source
- One account (multi-account scope removed), OAuth API uid compared to authenticated Chrome uid before any web photo operations.
- Unlimited photo guided workflow with explicit move confirmation and quota/list gate.
- Vendored, adapted MIT-origin `yd.js` that refuses incomplete list and retains move journal.
- Per-photo immutable manifest and verified/failed/remaining summary CSV; bounded in-session retry of partial move results.
- `rclone check --download` for photo rescue, fail-closed full-success status.
- Worker queue in SQLite with WAL and transactional migration from old JSON; per-user mutex; retries and guarded destination volume identity.
- Worker pause/cancel and local-user autorun after logon (opt-in); scheduled and daily-repeated standard copy jobs.
- Isolated Chrome profile, non-fixed loopback debugging port, guarded profile removal; SHA256-pinned built-in helper script.
- Local HTML+CSV reports, token protection via DPAPI, environment-only rclone remote (no plaintext token config), default no telemetry.
- Source-level Windows packaging for GUI+Worker+Node+Playwright+rclone, Inno Setup option.

## Pending proof (cannot claim complete)
- WPF/.NET build on Windows (SDK unavailable here).
- Running Node/Playwright/Chrome/Yandex internal API on Windows; confirm disk API uid filtering and cloud-folder creation.
- Full real-account rescue, >10,000 files and several TB scenario.
- Outbound-traffic audit including npm/dependency downloads and any future updates.
- Signed installer and Windows SmartScreen behavior (no signing certificate). Portable/installer *build scripts* exist, finished Windows binaries not produced here.
- Installer-update rollback and uninstaller session cleanup. Background worker logon autostart is not equivalent to a system service or a watchdog after arbitrary process crashes; test and strengthen if needed.

Do not use this build as the only copy of important photos.
