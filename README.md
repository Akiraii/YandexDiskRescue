# Yandex Disk Rescue — consolidated implementation (one account)

## Required scope

- One Yandex Disk account, one protected OAuth token, one persisted local SQLite (WAL) job queue.
- Unlimited photos: Chrome isolation → enumerate and validate list → explicitly approved move → queue download → stream-based content check → local CSV/HTML report.
- Separate worker, per-user logon startup (opt-in), pause/cancel queued or running jobs, retries of temporary errors; optional daily recurrence for normal backups (not cloud-modifying photo moves).
- Source and local backups are never deleted. rclone uses `copy --immutable`, **never** `sync` or delete.
- Destination volume serial is captured when a job is created and checked before writing.
- CSV distinguishes verified, not moved, missing, different and uncertain photos. Full success only if every item was verified.
- Reports, sensitive metadata, Chrome cookies and token are local-only. OAuth is saved only with user consent via Windows DPAPI; rclone receives it only via per-child environment variables (never command arguments or plaintext temp files).

## Building (Windows 10/11 x64)

On a trusted build machine install .NET 8 SDK, Node.js/npm, official rclone, and optionally Inno Setup 6. Run `build-windows.ps1`. It installs pinned `playwright-core` 1.63.0 into the bundled tools folder (npm lock generated once on the build host), publishes WPF and Worker as self-contained executables, bundles node/rclone/helper, and generates Portable ZIP plus installer when Inno Setup is available.

Resulting user installation is self-contained. No PowerShell/npm/dotnet needed on the end user's computer.

### First run

1. Start GUI; enter Yandex Polygon token; check optional DPAPI persistence for background jobs, click connect.
2. Choose a destination folder (ensure external disk has adequate space). Optionally enable Worker launch after Windows logon.
3. Under unlimited photos open isolated Chrome and sign in to `disk.yandex.ru` using the SAME account.
4. Click `Спасти фото: полный мастер`. Confirm cloud-side changes and quota usage. After confirmation the app creates the cloud folder `Безлимит` if it does not exist.
5. A manifest is captured. Copy and `rclone check --download` execute through Worker. Open report for final result.
6. If Yandex returns partial API errors, open local CSV report, resolve and re-run moves/download. Files missing after move are not reported as safe.
7. Revoke OAuth after finishing and use `Удалить сохранённый токен`, then close Chrome and remove isolated Chrome profile.

## Security caveats

- `yd.js` uses undocumented Yandex web API through the Chrome DevTools local port, and can change without notice.
- Chrome picks an ephemeral loopback port and a separate ACL-restricted profile, but **other software running as the same OS user** might still reach its debugging interface. Do not use untrusted software at the same time.
- Files/data are not uploaded to any developer server, and telemetry/updaters are not implemented. However, network egress must be audited to substantiate that claim for actual binaries.
- Remote content integrity is checked with `rclone check --download`, which streams all files AGAIN and may take as long as original downloading; matching metadata alone is not treated as proof.
- The user approves cloud-side `move` explicitly; moving affects ordinary storage quota. The app does not delete anything from cloud, but this is not a read-only action.
- The saved OAuth token is encrypted with DPAPI; active Chrome cookies are NOT DPAPI-encrypted and must be removed when finished. The token is also temporarily present in process memory/environment while copying and may be accessible to sufficiently privileged local software.
- Program can't rescue inaccessible objects that Yandex doesn't deliver; report such objects explicitly.

## Current verification boundary

The source project is prepared for a Windows build, **not compiled or exercised on Windows in this environment**, and no real account has been used. This is not a validated production rescue tool until Windows compilation, end-to-end tests, fault injection, and network capture have been completed. See `RELEASE-STATUS.md`.

## Migrating old versions

The original `jobs.json` is imported into SQLite transactionally on first run when the SQLite queue is empty, then renamed to `.migrated`. Existing jobs without a saved destination-volume serial must be re-confirmed from the GUI before processing.
