# Upstream tag mirroring strategy

This document explains why [`skaraMirror.sh`](skaraMirror.sh) failed with a duplicate `_adopt` tag on jdk27u, and defines which upstream tags each upstream branch should mirror to avoid it.

## The problem: duplicate `_adopt` tagging of `jdk-27.0.1+9`

Upstream tags are not always applied on `master`. For Oracle managed repos (and for CSPU branches), the tag is sometimes applied on a feature or update branch (for example `jdk27.0.1`) and that branch is later merged into `master`.

This is what happened with `jdk-27.0.1+9` in jdk27u:

1. `jdk-27.0.1+9` was tagged on the upstream `origin/jdk27.0.1` branch.
2. `origin/jdk27.0.1` was later merged into `origin/master`.
3. `git tag --merged` therefore returns `jdk-27.0.1+9` for **both** `origin/jdk27.0.1` and `origin/master`.
4. The mirror iterates the branches. On the first one, `jdk27.0.1`, it merges the tag into `release_jdk27.0.1` and tags the result `jdk-27.0.1+9_adopt`.
5. The mirror then iterates the tags reachable from `origin/master`, finds `jdk-27.0.1+9` again, and merges it into `release`. It then tries to tag `jdk-27.0.1+9_adopt` a second time.
6. The `_adopt` tag already exists, so the tag step fails and the whole mirror job fails.

The job fails at the second `_adopt` tag. The root cause is that the mirror does not decide consistently which branch is responsible for which tag, so the same upstream tag is processed from two branches. We have not verified that processing a tag twice, merging it into two different release branches, is safe in general.

### Decision: `_adopt` tagging stays strict, with one narrow exception

Making the tag step tolerate any existing `jdk-27.0.1+9_adopt` would hide the symptom and leave the cause. With the strategy below, each upstream tag is mirrored from exactly one branch, **except** for the one legitimate case described under [Paired branches](#paired-branches-the-only-allowed-duplicate). In every other case, if `<tag>_adopt` already exists, the branch filters overlap or are wrong, and the job must keep failing so that the filters get fixed.

## The fix: each upstream branch mirrors only its own tags

Instead of mirroring every tag reachable from a branch, each branch mirrors only the tags whose version matches that branch. Matching is a strict regular expression applied to the output of `git tag --merged`, not a glob, because a glob cannot express "exactly three version components". For example, `jdk-27.0.1+` must not match `jdk-27.0.1.0.2+3`.

The default branch (`master`) does **not** need to know the "current update version". It mirrors every tag of the right shape, and the existing merge loop only merges tags that sort after the newest tag already on `release`. In jdk11u to jdk27u the sequence `jdk-21.0.32+8`, `jdk-21.0.32+9`, `jdk-21.0.33+1` is therefore mirrored in order without any version bookkeeping.

Upstream repos tag and branch differently, so the rules differ slightly per repo.

| Repo | Upstream branch | Tag regex | Mirror branch |
|---|---|---|---|
| jdk (head) | `master` | `^jdk-[0-9]+\+[0-9]+$` (one version component) | `release` |
| jdk (head) | feature branch (`origin/jdk27`) | `^jdk-27\+[0-9]+$`. Partner of `master`. See [Paired branches](#paired-branches-the-only-allowed-duplicate). | `release_jdk27` |
| jdk11u to jdk27u | `master` | `^jdk-MM\.0\.[0-9]+\+[0-9]+$`, exactly three version components, with `MM` taken from the repo name (for example `^jdk-11\.0\.[0-9]+\+[0-9]+$`). Upstream tags the build commit (for example `jdk-11.0.32+8`). The mirror merges that tag commit into `release` and tags it `jdk-11.0.32+8_adopt`. | `release` |
| jdk11u to jdk27u | CSPU or sub-update branch with four or more components (`origin/jdk11.0.32.1`, `origin/jdk27.0.1.0.2`) | The branch version followed by `+`, for example `^jdk-11\.0\.32\.1\+[0-9]+$` or `^jdk-27\.0\.1\.0\.2\+[0-9]+$`. The mirror merges each matching tag commit into the matching release branch and tags it `_adopt`. | `release_<branch>` (for example `release_jdk11.0.32.1`) |
| jdk11u to jdk27u | normal update branch with exactly three components (`origin/jdk27.0.2`) | `^jdk-27\.0\.2\+[0-9]+$`. **Mirrored**, not ignored. See [Paired branches](#paired-branches-the-only-allowed-duplicate). | `release_jdk27.0.2` |
| jdk8u | `master` | `^jdk8u[0-9]*2-b[0-9]+$`. Mainline versions always end in `2` (`jdk8u502`, `jdk8u512`, `jdk8u522`, `jdk8u532`), increasing by 10 for each quarterly CPU. | `release` |
| jdk8u | CSPU branch (`origin/openjdk8u504`) | Strip `open` to get `jdk8u504`, then `^jdk8u504-b[0-9]+$`. CSPU versions never end in `2`, so they cannot overlap with `master`. No partner. | `release_openjdk8u504` |
| jdk8u | update branch whose version ends in `2` (`origin/openjdk8u512`) | Strip `open` to get `jdk8u512`, then `^jdk8u512-b[0-9]+$`. Partner of `master`. See [Paired branches](#paired-branches-the-only-allowed-duplicate). | `release_openjdk8u512` |
| aarch32-port-jdk8u | `master` | Same as jdk8u `master` plus the date suffix: `^jdk8u[0-9]*2-b[0-9]+-aarch32-[0-9]+$` | `release` |
| aarch32-port-jdk8u | CSPU branch | Same as jdk8u CSPU plus the suffix: `^jdk8uNNN-b[0-9]+-aarch32-[0-9]+$` | `release_<branch>` |

Notes on the regexes:

- jdk8u uses `-b*`, never a bare `jdk8u504-` prefix. A bare prefix would also match `jdk8u504-ga`, which must never be mirrored.
- Fork-point tags (`…+0` and `…-b00`) still match the regexes but are dropped by the existing sort command, as today.
- The jdk8u "ends in `2`" rule applies to the versions currently mirrored (8u212 onward). Older tags such as `jdk8u201` never sort after the newest tag on `release`, so the merge loop ignores them.
- In the jdk (head) repo, the `master` regex matches any one-component tag, including `jdk-27+N` tags created on `master` before `jdk27` was forked. Those overlap the `jdk27` branch filter, and `release_jdk27` is created from one of them. This is expected, and it is exactly what the partner rule covers: `master` and `jdkMM` are partners.

### Branch classification

The branch name decides which rule applies:

| Branch name | Class | Rule | Partner |
|---|---|---|---|
| The upstream default branch | mainline | per the table above | the matching update or feature branch, per tag |
| `jdkNN` (one component) | head feature branch | `^jdk-NN\+[0-9]+$` | `master` |
| `jdkMM.0.VV` (exactly three components) | update branch | `^jdk-MM\.0\.VV\+[0-9]+$` | `master` |
| `jdkMM.0.VV.x[.y…]` (four or more components) | CSPU or sub-update branch | branch version followed by `+`, strict | none |
| `openjdk8uNN2` (version ends in `2`) | jdk8u update branch | `^jdk8uNN2-b[0-9]+$` | `master` |
| `openjdk8uNNN` (version does not end in `2`) | jdk8u CSPU branch | `^jdk8uNNN-b[0-9]+$` | none |
| Anything else | unrecognised | skip the release and dev steps with a warning | none |

An unrecognised branch (a port, a project branch, an experimental branch) is skipped with a warning. The upstream rebase and push to the mirror branch of the same name still runs, so the mirror stays a faithful copy. Only the release and dev steps are skipped. The job does not fail.

### Paired branches: the only allowed duplicate

The same build tag can legitimately be seen from two upstream branches: a versioned branch, and `master` once that branch is merged into it. We mirror both, because upstream might tag a GA on the versioned branch and never merge it into `master`. Mirroring from `master` only would then never pick it up.

The two branches are **partners**. The partner is chosen by the shape of the tag:

| Repo | `master` partners with | For tags of the form | Partner mirror branch |
|---|---|---|---|
| jdk (head) | `jdkMM` | `jdk-MM+BB` | `release_jdkMM` |
| jdkMMu (jdk11u and later, any future repo) | `jdkMM.0.VV` | `jdk-MM.0.VV+BB` | `release_jdkMM.0.VV` |
| jdk8u and aarch32-port-jdk8u | `openjdk8uNN2` | `jdk8uNN2-bBB` (aarch32 adds `-aarch32-<date>`) | `release_openjdk8uNN2` |

- Seen from the versioned branch, the partner is always `master` (mirror branch `release`).
- No other branch has a partner. CSPU and sub-update branches stay strict.
- Partners are derived from the tag and branch shape only, with no hard-coded versions. See [No per-repo version logic](#no-per-repo-version-logic).

When a partner pair both mirror the same build tag, the second one to run finds `<tag>_adopt` already present. Every `_adopt` tagging step then applies this rule instead of failing. That includes both the merge loop and the tagging of the base tag of a brand new release branch:

1. Work out the partner mirror branch `P` for the tag being tagged, using the table above.
2. The existing `<tag>_adopt` is accepted only if it is reachable from `origin/<P>` (for example `git merge-base --is-ancestor <tag>_adopt origin/<P>`) **and** is not reachable from the release branch currently being processed.
3. If accepted, log it, skip only the `git tag` and its push, and continue. The upstream tag is still merged into the current release branch, so that branch keeps advancing and `git tag --merged` keeps working on later runs.
4. If the tag exists anywhere else (including a branch that is not the partner), or on the current release branch itself, fail as today.

Only the specific partner branch is checked. `dev` and `dev_*` branches are never used for this check, even though they contain `release`.

This covers both orders in which Oracle can do things:

| Order | First run | Second run |
|---|---|---|
| Update branch first, merged into `master` later | `release_jdk27.0.1` gets `jdk-27.0.1+9_adopt` | `master` run finds the tag on `release_jdk27.0.1`: accepted, tag skipped, upstream tag merged into `release` |
| `master` first, update branch created later (for example two days after the GA stream is merged into `master`) | `release` gets `jdk-27.0.1+9_adopt` | `jdk27.0.1` run finds the tag on `release`: accepted, tag skipped, upstream tag merged into `release_jdk27.0.1` |

Both orders work, so correctness does not depend on the order in which the [`Jenkinsfile`](Jenkinsfile) iterates the branches. The Jenkinsfile still processes the default branch **last**, so that logs and results are deterministic, and so that in the common case (update branch first, `master` later) the partner check is exercised in one direction only. The Jenkinsfile removes the default branch from the active set and appends it at the end.

The release trigger ([`triggerReleasePipeline.sh`](triggerReleasePipeline.sh)) finds `<tag>_adopt` with `git ls-remote --tags` across the whole repo. It does not care which mirror branch holds the tag, so a release can be built from either location.

The base tag of a brand new release branch follows the same rule, through the same `tagAdopt` helper in [`skaraMirror.sh`](skaraMirror.sh). Previously that path silently skipped an existing tag with no check of where it lived. This matters in the head repo: `release_jdk27` is created from a pre-fork tag such as `jdk-27+25`, which `master` has already tagged `_adopt` on `release`, and the partner rule accepts exactly that.

## How tags reach `master` in each repo

- **jdk11u to jdk25u:** builds happen in a separate `jdkNNu-dev` repo and are merged into `master` as a commit stream. Upstream tags the build commit. CSPU branches (for example `origin/jdk11.0.32.1`) are created from a `master` tag (for example `jdk-11.0.32.1+0`). Their tags, including the GA tag, are applied on the branch, and the branch is then merged into `master`. There is typically no normal `jdkMM.0.VV` update branch.
- **jdk27u (Oracle managed):** there is no `-dev` repo. Build tags reach `master` through update branches. `master` and the sub-update branches (for example `origin/jdk27.0.1.0.2`) follow the same mirror logic as jdk11u to jdk25u. The normal update branch (`jdkMM.0.VV`) is partnered with `master`. See [Paired branches](#paired-branches-the-only-allowed-duplicate). This applies to any Oracle managed repo, including future ones (for example jdk28u).
- **jdk (head):** new versions are created here and tagged `jdk-MM+BB`. Update versions are developed in the update repos. When a version is forked into a `jdkMM` branch, that branch is partnered with `master`.
- **jdk8u:** the strategy is the same as jdk11u to jdk25u, but the naming differs. Build tags are `jdk8uMMM-bBB`, and mainline versions end in `2`. CSPU branches are named `openjdk8uMMM` with a version that does not end in `2`. A branch named `openjdk8uNN2` is an update branch partnered with `master`.
- **aarch32-port-jdk8u:** same naming and numbering rules as jdk8u, with an extra `-aarch32-<date>` suffix on each tag. It mirrors to the Adoptium repo `aarch32-jdk8u`.

## No per-repo version logic

The only repo with its own rules is jdk8u (and its aarch32 variant), because its naming scheme differs. For every other repo the script must contain **no repo-specific or version-specific logic**:

- No hard-coded list of repos or version numbers, and no `if jdk27u` style cases.
- The `jdkNNu` rules are derived only from the generic repo name pattern (`MM` is parsed from `jdkMMu`) and from the branch name. A future Oracle managed repo such as jdk28u must work with no script change.
- Paired branches are detected by branch-name and tag shape (`jdkMM`, `jdkMM.0.VV`, `openjdk8uNN2` and the default branch), not by repo name. In repos that never have such a branch (jdk11u to jdk25u), the pairing rule simply never triggers.
- The jdk (head) repo is recognised by having no version in its name. Its rules are likewise generic: `jdkNN` feature branches are derived from the branch name.

The test harness must include a synthetic repo with a version that does not exist today (for example `jdk99u`) to prove this.

## Other rules

- `-ga` tags are never mirrored or `_adopt` tagged. In jdk and jdk11u+, the `-ga` form (for example `jdk-11.0.32-ga`) is the only tag that uses `-`. The matching `jdk-…+BB` tag on the same commit is the one that gets `_adopt`. The regexes already exclude `-ga` tags. As a safeguard, the sort command also gets `grep -v -- '-ga$'`.
- `_adopt` tagging stays strict. If `<tag>_adopt` already exists and the [paired-branch rule](#paired-branches-the-only-allowed-duplicate) does not apply, the job fails, because it means the branch filters overlap.
- **No eligible tags is not an error.**
  - The sort command ends in `grep -v '+0$'`, and [`skaraMirror.sh`](skaraMirror.sh) runs with `set -e` and `pipefail`.
  - A new CSPU branch that only has its `jdk-11.0.32.1+0` fork tag produces an empty list, `grep` returns 1, and the whole job would die. The old broad filter never produced an empty list.
  - The tag listing must therefore tolerate an empty result (for example `|| true` on the filters, and an explicit empty check afterwards).
  - If there are no eligible tags, the release and dev steps are skipped with a log message, and the script exits 0. The same applies when creating a new release branch: with no base tag, nothing is created.
- **Unrecognised branch names** skip the release and dev steps with a warning, as described under [Branch classification](#branch-classification).

## Implementation outline

1. Add a classification function that maps the branch name to a class and a tag regex, or to "skip".
2. Add one helper, `listBuildTags <ref>`, that replaces the five `git tag --merged … $TAG_SEARCH` call sites. It applies the regex, the `-ga` filter and the existing sort, and tolerates an empty result.
3. Add one helper for `_adopt` tagging that implements the strict rule and the partner exception, with the partner derived from the tag shape. It is used by both the merge loop and the new-release-branch path.
4. Return early from the release and dev steps when `listBuildTags` is empty or the branch is unrecognised.
5. Keep the upstream rebase and push for every active branch.
6. In the [`Jenkinsfile`](Jenkinsfile), remove the default branch from the branch set and process it last.
7. Keep all version handling generic, as described under [No per-repo version logic](#no-per-repo-version-logic). The only special case is `VERSION == 8`.

## Test harness

The `tests/` directory builds synthetic local bare repositories for the upstream (Skara) side and for the Adoptium mirror side, then runs [`skaraMirror.sh`](skaraMirror.sh) against them. No network access is needed. Run all scenarios with `tests/run.sh`, or a subset with `tests/run.sh <name-filter>`. Each scenario asserts the exact set of `_adopt` tags per mirror branch.

[`skaraMirror.sh`](skaraMirror.sh) supports three optional environment variables for this, none of which are used in production: `SKARA_REPO_URL` (the upstream location), `MIRROR_WORKSPACE` (the working directory) and `MIRROR_PATCHES` (the patches directory).

| Scenario | Expected result |
|---|---|
| jdk27u duplicate: `jdk-27.0.1+9` tagged on `jdk27.0.1`, then the branch is merged into `master` (original failure) | Job succeeds. Exactly one `jdk-27.0.1+9_adopt`, located on `release_jdk27.0.1`. `release` contains the merged upstream tag but no `_adopt` tag. |
| Reverse order: GA stream merged into `master` first, `jdk27.0.1` created and the tag merged into it later | Job succeeds on both runs. Exactly one `_adopt` tag, located on `release`. |
| Update branch tags a GA and is never merged into `master` | Tag is mirrored from the update branch. |
| Existing `_adopt` tag found on an unrelated branch (not a partner) | Job fails. |
| Existing `_adopt` tag found on the branch currently being processed | Job fails. |
| CSPU branch `jdk11.0.32.1` merged into `master` | Its tags exist only on `release_jdk11.0.32.1`. None leak into `release`. |
| New CSPU branch with only the `+0` fork tag | Job exits 0 and skips release and dev. |
| Unrecognised branch name | Job exits 0 with a warning and skips release and dev. The mirror branch is still rebased and pushed. |
| Sequence on `master`: `jdk-21.0.32+8`, `+9`, `jdk-21.0.33+1` | Merged and tagged in order. |
| Head repo after the `jdk27` fork | `master` mirrors `jdk-28+`, `jdk27` mirrors `jdk-27+`. `release_jdk27` is created from the pre-fork `jdk-27+25`, whose `_adopt` tag already exists on `release`. The partner rule accepts it and the job succeeds. |
| Head repo, existing `_adopt` tag for `jdk-27+25` found on a non-partner branch | Job fails. |
| jdk8u `openjdk8u512` partner branch, both run orders | Same behaviour as the jdk27u partner scenarios: exactly one `jdk8u512-bNN_adopt` tag. |
| jdk8u CSPU branch (version not ending in `2`) has an overlapping `_adopt` tag | Job fails. CSPU branches have no partner. |
| Synthetic future repo `jdk99u` (no such repo exists today) with a `master`, a `jdk99.0.1` update branch and a CSPU branch | Same behaviour as jdk27u, with no script change. |
| Jenkinsfile branch ordering | The default branch is always last in `BRANCHES_TO_MIRROR`, whether or not it was already in the active set. |
| jdk8u | `-ga` and `-b00` tags are ignored. Versions not ending in `2` are never mirrored from `master`. CSPU `jdk8u504-b*` tags are mirrored only from `openjdk8u504`. |
| aarch32-port-jdk8u | Tags with the `-aarch32-<date>` suffix are mirrored. Same `2` and CSPU separation as jdk8u. |
| Filters deliberately overlapping (negative test) | Job fails on the existing `_adopt` tag. |
