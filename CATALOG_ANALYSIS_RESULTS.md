# Catalog Analysis Results

**Analysis Date:** 2026-08-24
**Sample:** 87 of 90 repos in the `rhpds` org's `zt-rhel-bu-developers` team with a `setup-automation/` directory
**Purpose:** Validate whether the lab setup library (see BASELINE_ANALYSIS.md) fits the real catalog, per CATALOG_ANALYSIS_PLAN.md

---

## Which library functions are useful across the catalog?

- **register_system** — 41 repos have an inline pattern matching this function (clean + register, or a close variant). Examples: `zt-helpful-commands`, `zt-file-access-policy`, `zt-rhel-ctf1`, `zt-webconsole-software`. This is by far the most broadly duplicated piece of logic in the catalog — present in labs with hardcoded activation-key/org literals, env-var-driven versions, and dead/commented-out versions alike.
- **setup_cockpit** — 17 repos write `/etc/cockpit/cockpit.conf` with an `Origins = https://cockpit-${GUID}.${DOMAIN}` line and enable the cockpit socket/service. Examples: `zt-idm-workshop`, `zt-imagebuilder`, `zt-webconsole-perf`, `zt-security-usbguard`. Nearly every match adds an extra `AllowUnencrypted = true` line the library function doesn't produce, and several skip the package-install step (assume cockpit preinstalled).
- **pull_images** — 7 repos have inline `podman pull` logic. Examples: `zt-image-mode-basics`, `zt-podman-basics`, `zt-podman-pods`, `zt-discovery-cli`. Most use `sudo -u <user>` or plain root pulls rather than the library's `runuser -l` pattern, and rarely pass `--authfile` explicitly.
- **setup_redhat_registry_auth** — 4 repos write a registry.redhat.io `auth.json` from a pull token. Examples: `zt-image-mode-basics`, `zt-image-mode-day2`, `zt-discovery-cli`, `zt-cla-on-prem`. All hardcode the destination path (e.g. `~/.config/containers/auth.json`) rather than using a `$RH_REGISTRY_AUTHFILE`-style variable.
- **add_local_host** — 4 repos append entries to `/etc/hosts`. Examples: `zt-image-mode-basics`, `zt-image-mode-day2`, `zt-idm-workshop`, `zt-rhel-system-roles-metrics`. `zt-idm-workshop` uses a materially different static-IP addressing scheme rather than the library's gateway-IP pattern.
- **fetch_setup_files** — 5 repos show a recurring need to deliver supporting content (Containerfiles, configs, static files) to an already-provisioned host — something the platform-templated main.yml harness doesn't provide, since it only ever stages the single setup script (see the migration-surface section below). 4 repos build that same kind of content inline via heredoc instead of fetching it: `zt-buildah`, `zt-podman-basics`, `zt-podman-containerfile`, `summit-2026-rhel-labs-zt-lb1577-1`. 1 repo, `zt-security-auditd`, has a commented-out block that hand-rolls the identical git-sparse-checkout mechanism, down to the same `setup-files` directory-naming convention the library uses.

## Which library functions show no independent evidence beyond the original design sample?

These functions replace inline code that some lab *does* write today, but show almost no presence outside the small cluster of repos (`zt-image-mode-basics`, `zt-image-mode-day2`) that look like they informed the library's original design:

- **setup_ssl_registry** — 2 repos, both `zt-image-mode-basics` and `zt-image-mode-day2`.
- **setup_libvirt** — 1 repo (`zt-image-mode-basics`).
- **persist_env_var** — 0 repos.

### New consistent `cleanup_*` needed

The four `cleanup_*` functions add teardown capability the catalog doesn't already have inline, so measuring them against existing duplication doesn't apply — there's no pattern for them to replace. The relevant question is whether the corresponding setup action exists in a repo, and whether the credentials it uses need to be removed before the student gets access.

Every one of these 87 repos is a roughly 1-hour live lab: setup-automation is the provisioning work that runs on the box before the student's hands-on session, not a background process on a machine the student never sees. Any activation key, org ID, or registry pull token used during `register_system` or `setup_redhat_registry_auth` stays readable on disk (in `subscription-manager` facts, `auth.json`, shell history, etc.) for the entire live session, on a box the student has direct access to. That's the exposure `cleanup_subscription`, `cleanup_registry_auth`, and `cleanup_certbot` close — it has nothing to do with whether the VM is destroyed afterward.

| Setup action | Repos with the action | Repos that remove the credential before handoff |
|---|---|---|
| `register_system` | 41 | 0 (`zt-using-file-permissions` calls `subscription-manager clean`, but only as a *pre*-registration reset, not a post-setup teardown) |
| `setup_redhat_registry_auth` | 4 | 1 (`zt-image-mode-day2`, partial — removes auth.json but doesn't call `podman logout`) |
| `setup_ssl_registry` | 2 | 2 (`zt-image-mode-basics`, `zt-image-mode-day2` — both scrub the certbot log that would otherwise contain the ZeroSSL EAB key/HMAC secret) |

Near-zero occurrence across the 41 `register_system` repos and 4 `setup_redhat_registry_auth` repos is a real, catalog-wide credential-exposure gap, not a sign that cleanup is unnecessary — every live student session built from one of those 41 repos currently hands the student a box with a working subscription-manager registration (and, in hardcoded-credential cases, the literal activation key/org ID in a readable script) for the full hour.

## What patterns did we miss?

- **Wheel-group sudo bootstrap for the lab user** (`usermod -aG wheel <user>` [+ hardcoded password]) — the most duplicated pattern in this list: active in 18 repos (`zt-unixisms`, `zt-rhel-pxh1`, `zt-rhel-ts1`, `zt-storage-web-console`, `zt-sandbox-withclient-2h`, `zt-openshift-poc`, `zt-security-usbguard`, `zt-security-auditd`, `zt-selinux-containers`, `zt-selinux-policy`, `zt-security-selinux`, `zt-convert2rhel-ol`, `zt-webconsole-software`, and five `summit-2026-rhel-labs-*` repos: `disk-space-deleted-files`, `lb1577-1`, `lvm-expansion`, `sudo-privesc-hunt`, `system-performance`) and present but commented out in 3 more (`zt-openscap`, `zt-session-recording-tlog`, `zt-webconsole-perf`).
- **Cloud-image GCP repo removal before subscription registration** — a GCP-marketplace-image concern (clearing the cloud provider's own package source before registering with Red Hat), showing up as two different commands for the same purpose: `yum remove -y google-rhui-client-rhel8.noarch` is active in 10 repos (`zt-discovery-cli`, `zt-rhel-ctf1`–`ctf5`, `zt-rhel-ctf13`, `zt-rhel-ts2`–`ts4`) and present but commented out in 2 more (`zt-podman-basics`, `zt-podman-pods`); `mv /etc/yum.repos.d/google-cloud.repo /root` does the same job in 3 repos (`zt-rhel-pxh1`, `zt-rhel-ts1`, `zt-sandbox-withclient-2h`, the latter in both its scripts).
- **Completion-signal breadcrumb** — two distinct idioms marking "setup finished" for the platform or a human watching the log, neither of which is a library function today: `echo "DONE" >> /root/post-run.log` in 13 repos (`zt-containerize-app`, `zt-crypto-policy`, `zt-eus-intro`, `zt-file-access-policy`, `zt-idm-workshop`, `zt-kpatch-apply`, `zt-python-venv`, `zt-rhel-pxh1`, `zt-rhel-ts1`, `zt-sandbox-withclient-2h`, `zt-service-admin`, `zt-tuned`, `zt-web-server-deploy`), and a `touch <logfile>.done` sentinel in 6 repos (`zt-discovery-cli`, `zt-imagebuilder-cli`, `zt-podman-pods`, `zt-selinux-policy`, `zt-session-recording-tlog`, `zt-webconsole-perf`).
- **Persistent tmux session via `crontab @reboot`** — 5 repos: `zt-eus-intro`, `zt-python-venv`, `zt-storage-web-console`, `zt-tuned`, `zt-kpatch-apply`; present but commented out in `zt-crypto-policy`. (`zt-appstream-manage` launches tmux directly at setup time but never wires it to `crontab @reboot`, so it doesn't restart after a reboot — a different, one-off pattern, not this one.)
- **EPEL repo enablement** (often as a certbot prerequisite) — active in 4 repos: `zt-image-mode-basics`, `zt-image-mode-day2`, `zt-security-usbguard`, `zt-rpmbuild`; present but commented out in 3 more (`zt-rhel-system-roles-metrics`, `zt-security-auditd`, `zt-security-selinux`).
- **Hostname randomization via `hostnamectl set-hostname rhel-$(uuidgen | cut -c 32-)`** — 4 repos: `zt-insights-vulnerability`, `zt-insights-workshop`, `zt-rhc`, `zt-insights-overview`.
- **`dnf --installroot` chroot/scratch image build** — active in 4 repos: `zt-podman-deploy`, `zt-selinux-containers`, `zt-webconsole-perf`, `zt-selinux-policy`; present but commented out in `zt-sandbox`. Two of the four active implementations reference an undefined `$scratchmnt` variable — broken as shipped.
- **Firewall-cmd service enablement** (open port + reload) — 4 repos: `zt-crypto-policy`, `zt-openscap`, `zt-firewall-system-role`, `zt-idm-workshop`.
- **Disable dnf-automatic updates** — 4 repos: `zt-satellite-basics` and `zt-lb1187-hands-on-with-lightspeed-in-satellite` do the full stop/disable/mask sequence; `summit-2026-rhel-labs-zt-lb1577-1` and `zt-image-mode-day2` use the shorter `systemctl disable --now dnf-automatic.timer`.
- **Timezone standardization via `timedatectl set-timezone`** — 3 repos: `zt-unixisms`, `zt-idm-workshop`, `zt-rhel-system-roles-metrics`.

**Recommendation:** all ten patterns above are lab-owned (live in setup-*.sh) and clear the plan's 3+ repo threshold, so they're legitimate common.sh candidates. Strongest by a wide margin: **wheel-group sudo bootstrap**, active or attempted in 21 of 87 repos — more catalog presence than every core function except `register_system`, and several instances hardcode the password being set, so a library function is also a chance to close that off. **Cloud-image GCP repo removal** (15 repos across both command variants) is next, and a candidate to fold into `register_system` as a cloud-image variant rather than a separate function. The `dnf --installroot` scratch-build pattern is worth prioritizing despite its lower count (5) because two of its four active implementations reference an undefined `$scratchmnt` variable — extracting to a tested library function fixes a live bug, not just duplication.

Observed but not frequent enough to add: SSH `StrictHostKeyChecking no` config drop-in (`zt-idm-workshop`, `zt-rhel-system-roles-metrics`); synthetic block-device creation via `truncate` + `losetup` (`zt-stratis`, `zt-storage-web-console`); bootc/bootc-image-builder blueprint templating (`zt-image-mode-basics`, `zt-image-mode-day2`); fapolicyd ansible-allow rule (`zt-file-access-policy`); Adminer single-file PHP tool install via wget (`zt-intro-to-databases`).

## What could move into the base image?

REQUIREMENTS.md already documents one case: `git` isn't present in the EUS image (`rhel-10-2-eus-*`), so every setup script targeting it must register a subscription and install git before it can even fetch the library — an ordering dependency that exists purely because of a missing base package. Catalog evidence reinforces this rather than just confirming it in isolation: of the 3 repos that call `git clone` directly, 2 (`zt-security-auditd`, `zt-web-server-deploy`) never install git at all — they assume it's already there, an assumption that doesn't hold on the EUS image.

`pull_images`'s dependencies show the same pattern. 10 repos run `podman` commands; 7 install `podman` or the `container-tools` module first (`zt-buildah`, `zt-containerize-app`, `zt-discovery-cli`, `zt-image-mode-basics`, `zt-image-mode-day2`, `zt-podman-basics`, `zt-podman-pods`), but 3 (`zt-cla-on-prem`, `zt-podman-containerfile`, `zt-satellite-advanced-topics`) use `podman` without installing it — the same kind of unverified preinstalled-assumption git has. `skopeo` is installed alongside `podman` in 2 of those repos. If `pull_images` is a core library function, guaranteeing `podman` and `skopeo` in the base image removes both a runtime install step and this existing latent assumption.

Two more packages are common enough to be worth the same conversation even though no library function depends on them: `tmux` (installed in 10 repos, mostly for the persistent-session pattern noted above) and `lsof` (7 repos, installed in the same command as `tmux` every time). Lower priority than `git`/`podman` since nothing blocks on their absence, but baking them in would remove a redundant install line from roughly a tenth of the catalog.

## What's the migration surface, and what's the level of effort vs. leaving things as they are?

Of the 87 repos analyzed, tiered by what migrating their `setup-*.sh` to the library would actually require:

| Tier | Count | What it takes |
|---|---|---|
| Drop-in swap | 12 | Call-site replacement only — main.yml already passes every var the matched function needs. `zt-file-access-policy`, `zt-idm-workshop`, `zt-imagebuilder`, `zt-insights-vulnerability`, `zt-insights-workshop`, `zt-performance-copilot`, `zt-rhel-system-roles-metrics`, `zt-sandbox`, `zt-satellite-basics`, `zt-service-admin`, `zt-container-management`, `zt-cla-on-prem`. Lowest effort tier: replace the inline block, verify behavior, done. |
| Swap + wire a var through main.yml | 5 | Same as above, plus adding one missing var to that main.yml's existing `vars`/`environment` block (not touching the dispatch harness itself). `zt-rhel-ctf1`–`ctf5` and similar cases where `ACTIVATION_KEY` or `LOG` is referenced in-script but never passed. Still mechanical, one extra step per repo. |
| Swap + fix hardcoded credentials first | 37 | The largest tier. A literal activation key/org ID (commonly `12-5-22-instruqt` / `12451665`) is baked into `subscription-manager register` instead of coming from a variable — `zt-unixisms`, `zt-stratis`, `zt-crypto-policy`, `zt-rhel-ts1`–`ts4`, and most of the CTF/TS family. Also notable: a plaintext Satellite admin password in `zt-lb1187-hands-on-with-lightspeed-in-satellite`, and a baked-in bootc image password (`redhat`) in `zt-image-mode-basics`/`zt-image-mode-day2`. Real per-repo work — add secrets.yaml, wire the var through main.yml, then swap the call — but it's fixing a pre-existing credential-hygiene problem the repo has today regardless of the library. |
| Matching code exists but is disabled | 1 | `zt-security-auditd` has a commented-out `setup_cockpit` block and a commented-out `fetch_setup_files` block (the same one cited as `fetch_setup_files` prior art above). Not a swap — someone would need to decide why it was turned off before turning it back on. |
| No match to the 13 core functions, but matches a recommended new pattern | 16 | Not migratable today because the function doesn't exist yet, not because there's nothing to migrate: `zt-firewall-system-role` (firewall-cmd), `zt-openshift-poc`, `zt-convert2rhel-ol`, and all 5 `summit-2026-rhel-labs-*` repos (`lb1577-1`, `lvm-expansion`, `disk-space-deleted-files`, `sudo-privesc-hunt`, `system-performance`) (wheel-group sudo), `zt-podman-deploy` (dnf --installroot), `zt-rhc` (hostname randomization), `zt-lb1187-hands-on-with-lightspeed-in-satellite` and `summit-2026-rhel-labs-zt-lb1577-1` again (disable dnf-automatic), `zt-eus-intro`, `zt-python-venv`, `zt-tuned`, `zt-kpatch-apply` (persistent tmux session), `zt-web-server-deploy` (completion-signal breadcrumb). Migration surface for these depends on the ten new-pattern recommendations above landing first. |
| No match to anything — no core function, no recommended pattern | 16 | Genuine empty stubs (`zt-command-line-assistant-problem-solving`, `zt-managing-user-basics`, `zt-rootless-podman-service`, `zt-insights-subscriptions`) or fully bespoke content with no shared pattern of any kind, including `zt-appstream-manage` (launches tmux directly at setup time but never wires it to `crontab @reboot`, so it doesn't match the persistent-tmux pattern above). Migrating buys nothing today, and nothing proposed above changes that. |

**Bug, unrelated to library migration:** 13 of the repos above (`zt-rhel-ctf1`–`ctf5`, `zt-rhel-ctf13`, `zt-rhel-ts1`–`ts4`, `zt-podman-basics`, `zt-podman-pods`, `zt-discovery-cli`) contain a wait loop — `while [ ! -f /opt/instruqt/bootstrap/host-bootstrap-completed ]` — and a `touch ${LOG}.done` / "Ready to start your scenario" completion signal written for Instruqt. These labs don't run on Instruqt. The current platform never creates that file, so as written the wait loop has no way to resolve. This needs fixing directly in those 13 repos; it isn't a library concern.

Continuing as-is doesn't avoid any of these costs: the 37 hardcoded-credential repos stay that way, the 5 var-gap repos stay broken in the same way, and every one of the 41 `register_system` call sites keeps drifting independently (unquoted vars, missing `dnf remove katello-ca-consumer-*`, inconsistent behavior) with no shared place to fix it once. The cost of not migrating is deferred and duplicated, not zero: the next time `register_system`-equivalent logic needs a fix, it's a 41-repo hand-edit instead of a one-line library change. Migration cost is front-loaded and one-time per repo; the status quo's cost is recurring and scales with every future fix.

## Should we proceed with this library?

Yes, proceed — the catalog has real, function-by-function evidence behind most of the library as built, plus ten more candidates worth adding. That evidence and the blockers to acting on it are two different things; separating them:

### Blockers (evidence only)

- **Hardcoded credentials** — 37 of 55 matched repos bake a literal activation key/org ID (commonly `12-5-22-instruqt` / `12451665`), a plaintext Satellite admin password, or a baked-in bootc image password directly into the script instead of reading a variable. These need fixing before a clean swap regardless of the library.
- **Var gaps** — 5 more matched repos reference a variable in-script (`ACTIVATION_KEY`, `LOG`) that main.yml never passes.
- **Inline drift from the library's exact implementation** — even where a function has strong evidence, existing inline copies aren't identical: `register_system` copies commonly use unquoted vars and skip `dnf remove katello-ca-consumer-*`; `setup_cockpit` copies often add an `AllowUnencrypted = true` line the library doesn't produce, or skip the package-install step; `pull_images` copies rarely pass `--authfile` explicitly. Migration is find-and-replace-with-verification per repo, not a mechanical swap.
- **One repo has matching code already written but disabled** — `zt-security-auditd`'s `setup_cockpit`/`fetch_setup_files`-equivalent blocks are commented out; reactivating them is a decision for that repo's owner, not a swap.

### What should be added or prioritized (recommendation only)

1. **Migrate now, well-evidenced:** `register_system` (41 repos), `setup_cockpit` (17), `pull_images` (7), `fetch_setup_files` (5).
2. **Migrate next, modest but real evidence:** `setup_redhat_registry_auth` (4), `add_local_host` (4).
3. **Add now regardless of catalog duplication:** `cleanup_*` — near-zero adoption today isn't a scoping signal, it's the credential-exposure gap itself (see above). Closes exposure on the 41 `register_system` and 4 `setup_redhat_registry_auth` repos.
4. **Keep as-is, no action needed:** `setup_libvirt`, `setup_ssl_registry`, `persist_env_var` — correctly serving the two labs they were built for; nothing here argues for removing them, catalog-wide demand just hasn't shown up yet.
5. **Add to the library, new patterns with 3+ repo evidence:** wheel-group sudo bootstrap (21 repos), cloud-image GCP repo removal (15), and the eight other patterns listed above.

## Coverage Summary
- Total repos in team: 90
- Repos with setup-automation/: 87
- Repos analyzed: 87
- Repos excluded (no setup-automation/): 3 (`showroom-lb1152-insights-on-prem`, `sovereign-cloud-showroom`, `zt-rhelbu-agnosticv`)

---

**End of Catalog Analysis Results**
