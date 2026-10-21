# Yandex Disk Rescue — Security audit, 2026-10-21

## Verdict: CONDITIONAL / NOT CLEARED FOR REAL PERSONAL DATA

This document records **static source review** and **CI dependency auditing**. It is **not** a penetration test, packet-level network audit, proof of absence of exfiltration, or a security certification. Before handling irreplaceable personal photos, perform controlled Windows runtime testing and a test-account Yandex rescue dry run.

### Scope
- Reviewed: Windows WPF GUI, Worker, shared services, embedded yd.js, installer and Windows build workflow.
- Compared: KenGuru66/yandex-disk-rescue upstream yd.js, Windows/Linux backup scripts, token-setup scripts, VPS automation and SECURITY.md.
- Third-party binaries: rclone version 1.75.2 is SHA-256 checked at build time; Node.js installed by setup-node, playwright-core locked with npm integrity; NuGet project references pinned and dependency audit enforced.
- **Not inspected fully**: binary implementation of rclone, Chromium, Node runtime, Windows and every transitive native library; no dynamic code execution under the user's Windows session.

### Findings and remediations

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| SEC-01 | High | rclone.exe could be resolved from PATH and receive OAuth through environment; Node helper likewise. | FIXED: packaged executables only, missing executable blocks execution. |
| SEC-02 | High | Transitive vulnerable native SQLite library, GHSA-2m69-gcr7-jv3q. | FIXED in project references: Microsoft.Data.Sqlite 8.0.32 plus SQLitePCLRaw.bundle_e_sqlite3 2.1.14. CI checks vulnerability database. |
| SEC-03 | Medium | No immutable dependency lock for npm. | FIXED: committed tools/package-lock.json with SHA-512 integrity, build uses npm ci and npm audit. |
| SEC-04 | Medium | Child-process logs could accidentally include credentials or signed URLs. | MITIGATED: token substitution and regex redaction, not a formal noninterference proof. |
| SEC-05 | Medium | CSV paths could be interpreted as spreadsheet formulas. | FIXED: neutralize leading formula characters before quoting. |
| SEC-06 | High residual | Chrome's DevTools TCP endpoint on localhost can be accessed by other local processes while it is open. | OPEN: separate locked-down browser profile, dynamic random loopback port and user confirmation reduce exposure, **but do not eliminate it**. Stronger solution: replace TCP CDP with a pipe or application-owned browser context. |
| SEC-07 | Medium residual | Unsigned, per-user-writable Windows installation; same-user malware may tamper with the EXE or bundled tools. | OPEN: code-sign and verify distributed packages; use a trusted Windows PC without malware. |
| SEC-08 | Critical to data availability | Internal Yandex photo API changes cloud paths and quota; partial moves/retries may be ambiguous. | REQUIRES LIVE TEST: manifest, quota check, explicit consent, copy-only and post-download content verification are implemented; API correctness not established. |
| SEC-09 | Unknown | Possible other outgoing destinations or sensitive data in runtime traffic. | NOT VERIFIED: packet capture/ETW and network allowlist review required during a real test. |

### Source-level observations
- GUI and Worker use rclone `copy` and `check`, not rclone `sync`, `delete` or `purge`.
- OAuth token is stored through DPAPI CurrentUser only if the user explicitly permits background processing. Child-process rclone token is passed in an environment variable rather than on the command line. **Same-user malware can still inspect memory or potentially child process data.**
- Unlimited helper talks to the Yandex web app through the already authenticated `disk.yandex.ru` page. The GUI's quota/folder calls go to `cloud-api.yandex.net`. Other network destinations may be used by rclone for file delivery; no deny-by-default firewall has been implemented.
- HTML report fields are HTML-encoded. CSV escaping was strengthened against formula injection.
- The app does not contain an explicit telemetry or developer-upload module in reviewed source. This is **not** an empirical guarantee about all network activity, dependencies or binaries.

### Build and dependency controls
- GitHub Actions dependencies are pinned to the exact upstream commit SHAs. `tools/yd.js` is SHA-256 pinned in C#, and LF is enforced by .gitattributes.
- Official rclone release ZIP download checked against a hardcoded SHA-256 in workflow.
- npm lock SHA-512 package integrity plus `npm audit --omit=dev --audit-level=high`.
- NuGet transitive vulnerability enumeration for both GUI and Worker; known moderate/high/critical findings fail release.
- The Inno Setup package installed with Chocolatey is not yet independently vendor-signed/reproducibly verified; Windows binary code signing is not configured.

### Required remaining acceptance tests on Windows
1. Use a non-production Yandex test account containing only synthetic files; keep production OAuth unused.
2. Record outgoing connections for GUI, Worker, Node, rclone and the isolated Chrome, then perform packet-level/ETW analysis. The helper `qa/windows-network-audit.ps1` records IP metadata only, and is **not sufficient by itself**.
3. Verify no token, session cookie, presigned URL or OAuth header is written to worker.log, UI output, CSV, HTML, diagnostics or crash dumps.
4. Test account mismatch, expired token, corrupted helper, replaced node/rclone binaries, suspicious path characters, failed report parsing and crafted filenames.
5. Run a minimal unlimited-photo rescue after explicit confirmation. Confirm all cloud moves, download hashes, expected counts, and no deletion; test deliberate disconnect and resume.
6. Verify installer signature (once a code-signing certificate is available), SmartScreen reputation, dependency provenance and VirusTotal/Defender scan of exact release binaries.
7. Do not promote to production until CDP port exposure is mitigated/accepted and actual traffic is reviewed.

### Limitations
- CI green means **build, static policy and known vulnerability checks passed**, not that data cannot be exfiltrated.
- New advisories can appear later; rerun dependency scans on each build.
- No audit can promise 100% safety against compromised Windows sessions or compromised upstream providers.

### Upstream
- https://github.com/KenGuru66/yandex-disk-rescue
- https://github.com/KenGuru66/yandex-disk-rescue/blob/main/SECURITY.md
- https://github.com/advisories/GHSA-2m69-gcr7-jv3q
