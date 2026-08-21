# Catalog Analysis Plan

**Purpose:** Validate whether the lab setup library fits the real catalog.

**Status:** Not started — documented for future execution.

---

## What We Want to Learn

1. Do the library functions solve problems that exist across the catalog?
2. Are there common patterns we completely missed?
3. What does migration actually look like at catalog scale?

---

## Execution Plan

### Step 1: Get repo list
```bash
gh api /orgs/rhpds/teams/zt-rhel-bu-developers/repos --paginate --jq '.[].name' > repos.txt
```

### Step 2: Fetch setup scripts
Workflow that:
- Takes repo list from step 1
- For each repo, fetches all `setup-*.sh` files from `setup-automation/` via raw.githubusercontent.com
- Stores: repo name, script names, script content
- Skips 404s silently (repos without setup-automation/)

### Step 3: Pattern extraction per repo
Each agent analyzes one repo's scripts and returns structured data:

```json
{
  "repo": "zt-foo-bar",
  "scripts": ["setup-builder.sh", "setup-rhel.sh"],
  "baseline_matches": {
    "register_system": "yes - line 12",
    "pull_images": "yes - lines 45-52, uses runuser pattern",
    "setup_ssl_registry": "no",
    "fetch_setup_files": "yes - heredoc pattern, 80 lines"
  },
  "new_patterns": [
    "ansible-runner install and config (15 lines)",
    "firewalld zone setup (8 lines)"
  ],
  "env_vars_present": ["GUID", "DOMAIN", "ACTIVATION_KEY"],
  "challenges": [
    "hardcoded org ID on line 15",
    "no GIT_REPO vars for sparse-checkout"
  ]
}
```

Match against these library functions:
- register_system
- setup_libvirt
- setup_cockpit
- setup_redhat_registry_auth
- pull_images
- setup_ssl_registry
- add_local_host
- persist_env_var
- fetch_setup_files
- cleanup_registry_auth
- cleanup_subscription
- cleanup_certbot
- cleanup_tmpfiles

### Step 4: Aggregate results
- Which baseline patterns appear? (list of repos per pattern)
- Which baseline patterns don't appear? (library functions with no catalog examples)
- New patterns appearing in 3+ repos (candidates for library addition)
- Migration challenge frequency (how many repos have hardcoded creds, missing vars, etc)

---

## Output Format

**This is a validation exercise, not another baseline document.**

The output is structured Q&A format answering specific questions:

### Q: Which library functions are useful across the catalog?
- `pull_images`: found in X repos (examples: ...)
- `setup_ssl_registry`: found in Y repos (examples: ...)
- `fetch_setup_files`: found in Z repos (examples: ...)

### Q: Which library functions appear to be baseline-specific?
- `setup_libvirt`: only found in N repos (same as baseline)
- `persist_env_var`: not found in any additional repos beyond baseline

### Q: What patterns did we miss?
- Pattern name: M repos (example implementations: ...)
- Pattern name: P repos (example implementations: ...)

### Q: What's the migration surface?
- Repos with all env vars needed: count
- Repos missing GUID/DOMAIN: count
- Repos with hardcoded credentials: count
- Repos with no matching patterns: count

### Q: Should we proceed with this library?
Qualitative answer based on above data.

---

## Explicitly NOT Doing

- Counting/percentaging catalog labs as validation ("57% have pattern X")
- Tiering catalog labs
- Building migration plans for specific labs
- Statistical validation claims
- Formatted document like the baseline

---

## Estimated Cost

~100 repos × 2-3k tokens per analysis = 200-300k tokens
Runtime: ~5-10 minutes with parallel workflow

---

## Prerequisites

- GitHub CLI authenticated to rhpds org
- Access to rhpds/zt-rhel-bu-developers team repos
- Workflow execution capability

---

## Notes

The baseline (BASELINE_ANALYSIS.md) documents what we built FROM — the 14 local labs that informed library design.

This catalog analysis validates whether what we built FITS the real catalog — the ~100 repos we maintain.

These are separate tasks with different purposes and output formats.
