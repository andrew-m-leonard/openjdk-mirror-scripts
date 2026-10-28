#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euxo pipefail

# Make sure we're in a valid dir as a workspace
# MIRROR_WORKSPACE and MIRROR_PATCHES are optional overrides, used by the tests/ harness.
# (WORKSPACE itself is not used as the override as Jenkins sets it for its own purposes.)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WORKSPACE=${MIRROR_WORKSPACE:-$SCRIPT_DIR/workspace}
mkdir -p "$WORKSPACE"
PATCHES=${MIRROR_PATCHES:-$SCRIPT_DIR/patches}/

# TODO generalise this for the non adoptium build farm case
function checkArgs() {
  if [ "$1" -lt 1 ]; then
     echo Usage: "$0" '[jdk8u|jdk17u]'
     echo "Skara Repo supplied should match a repository in https://github.com/openjdk/"
     echo "For example, to mirror https://github.com/openjdk/jdk17u"
     echo "e.g. $0 jdk17u"
     exit 1
  fi
}

# For jdk8u-based repos, common/autoconf/generated-configure.sh is a build-generated file
# that frequently conflicts during merges/rebases/patches because it is regenerated from
# common/autoconf/*.m4 sources. This function checks if it is the ONLY conflict and if so,
# regenerates it via autogen.sh and stages the result.
# Must be called from within the repo working directory.
# Returns 0 if the conflict was resolved, 1 if there are other conflicts (caller must fail).
function resolveGeneratedConfigureConflict() {
  local GENERATED_CONFIGURE="common/autoconf/generated-configure.sh"
  local AUTOGEN="common/autoconf/autogen.sh"

  # Only applies to jdk8u-based repos that have the autogen script
  if [[ "${VERSION}" != "8" ]]; then
    return 1
  fi

  # Get list of conflicted files
  local conflicts
  conflicts=$(git diff --name-only --diff-filter=U)

  if [[ -z "$conflicts" ]]; then
    return 1
  fi

  # Check if generated-configure.sh is the only conflict
  if [[ "$conflicts" != "$GENERATED_CONFIGURE" ]]; then
    echo "ERROR: Conflicts exist in files other than $GENERATED_CONFIGURE:"
    echo "$conflicts"
    return 1
  fi

  echo "Resolving $GENERATED_CONFIGURE conflict by regenerating via autogen.sh"
  if [ ! -f "$AUTOGEN" ]; then
    echo "ERROR: $AUTOGEN not found — cannot regenerate $GENERATED_CONFIGURE"
    return 1
  fi

  bash "$AUTOGEN" || return 1
  git add "$GENERATED_CONFIGURE" || return 1
  echo "Successfully regenerated and staged $GENERATED_CONFIGURE"
  return 0
}

function cloneGitHubRepo() {
  cd "$WORKSPACE" || exit 1
  # If we don't have a $GITHUB_REPO locally then clone it from adoptium/$GITHUB_REPO.git
  if [ ! -d "$GITHUB_REPO" ] ; then
    git clone "$REPO" "$GITHUB_REPO" || exit 1
  else
    # A workspace left over from a previous run may have been cloned from a different repo (for
    # example the real adoptium repo when this run is for a fork). Everything after this fetches
    # from and pushes to its origin, so never carry on with an origin that is not $REPO.
    local existingOrigin
    existingOrigin=$(git -C "$GITHUB_REPO" remote get-url origin 2>/dev/null) || existingOrigin=""
    if [[ "$existingOrigin" != "$REPO" ]]; then
      echo "ERROR: existing workspace $WORKSPACE/$GITHUB_REPO has origin '${existingOrigin:-<none>}' but this job is mirroring to '$REPO'"
      echo "Delete $WORKSPACE/$GITHUB_REPO (or run the job with CLEAN_MIRROR_WORKSPACE) and run it again"
      exit 1
    fi
  fi
}

function addSkaralUpstream() {
  cd "$WORKSPACE/$GITHUB_REPO" || exit 1

  git fetch --all

  # Ensure the skara remote exists before we need it
  # shellcheck disable=SC2143
  if [ -z "$(git remote -v | grep 'skara')" ] ; then
    echo "Initial setup of $SKARA_REPO"
    git remote add skara "$SKARA_REPO"
  fi

  # Fetch skara so skara/$BRANCH is available for branch creation below
  git fetch skara

  if ! git checkout -f "$BRANCH" ; then
    if ! git rev-parse -q --verify "origin/$BRANCH" ; then
      # Branch does not exist locally or on origin — create it from skara/$BRANCH
      # so it starts at the correct upstream commit, not the current HEAD
      git checkout -b "$BRANCH" "skara/$BRANCH" || exit 1
    else
      git checkout -b "$BRANCH" "origin/$BRANCH" || exit 1
    fi
  else
    # Only reset to origin/$BRANCH if it has been pushed there previously
    if git rev-parse -q --verify "origin/$BRANCH" ; then
      git reset --hard "origin/$BRANCH" || exit 1
    else
      echo "No origin/$BRANCH exists yet, skipping reset"
    fi
  fi
}

function performMergeFromSkaraIntoGit() {
  git fetch skara --tags

  if ! git rebase "skara/$BRANCH" "$BRANCH" ; then
    if resolveGeneratedConfigureConflict ; then
      git rebase --continue || exit 1
    else
      git rebase --abort
      exit 1
    fi
  fi

  git push -u origin "$BRANCH" || exit 1
  git push origin "$BRANCH" --tags || exit 1
}

# Decide which upstream tags the current upstream branch ($BRANCH) is responsible for mirroring.
# See TAG_MIRRORING_STRATEGY.md. Uses GITHUB_REPO, VERSION, BRANCH and SKARA_DEFAULT_BRANCH.
# There is no repo or version specific logic here other than the jdk8u naming scheme:
# the jdkNNu rules are derived from the repo name (VERSION) and the branch name only.
#
# Sets:
#   BRANCH_CLASS  mainline | update | cspu | head-feature | unknown
#   TAG_REGEX     extended regex (grep -E) that the build tags of this branch must match
function classifyBranch() {
  BRANCH_CLASS="unknown"
  TAG_REGEX=""
  local re ver verRe

  if [[ "${VERSION}" == "8" ]]; then
    # jdk8u: tags are jdk8uNNN-bBB. Mainline versions always end in 2 (502, 512, ...), and CSPU
    # branches (openjdk8uNNN) never do. aarch32-port-jdk8u tags carry an extra -aarch32-<date>.
    local suffix=""
    if [[ "${GITHUB_REPO}" == "aarch32-port-jdk8u" ]]; then
      suffix='-aarch32-[0-9]+'
    fi
    re='^openjdk8u([0-9]+)$'
    if [[ "${BRANCH}" == "${SKARA_DEFAULT_BRANCH}" ]]; then
      BRANCH_CLASS="mainline"
      TAG_REGEX="^jdk8u[0-9]*2-b[0-9]+${suffix}\$"
    elif [[ "${BRANCH}" =~ $re ]]; then
      ver="${BASH_REMATCH[1]}"
      if [[ "${ver}" == *2 ]]; then
        BRANCH_CLASS="update"
      else
        BRANCH_CLASS="cspu"
      fi
      TAG_REGEX="^jdk8u${ver}-b[0-9]+${suffix}\$"
    fi
  elif [[ -n "${VERSION}" ]]; then
    # jdkNNu: tags are jdk-NN.0.VV+BB on the default branch (exactly three version components),
    # on a jdkNN.0.VV update branch, or on a jdkNN.0.VV.x[.y...] CSPU / sub-update branch.
    if [[ "${BRANCH}" == "${SKARA_DEFAULT_BRANCH}" ]]; then
      BRANCH_CLASS="mainline"
      TAG_REGEX="^jdk-${VERSION}\\.0\\.[0-9]+\\+[0-9]+\$"
    else
      re="^jdk${VERSION}\\.0\\.[0-9]+\$"
      if [[ "${BRANCH}" =~ $re ]]; then
        BRANCH_CLASS="update"
      else
        re="^jdk${VERSION}\\.0\\.[0-9]+(\\.[0-9]+)+\$"
        if [[ "${BRANCH}" =~ $re ]]; then
          BRANCH_CLASS="cspu"
        fi
      fi
      if [[ "${BRANCH_CLASS}" != "unknown" ]]; then
        # jdk27.0.1.0.2 -> ^jdk-27\.0\.1\.0\.2\+[0-9]+$
        verRe=$(printf '%s' "${BRANCH#jdk}" | sed 's/\./\\./g')
        TAG_REGEX="^jdk-${verRe}\\+[0-9]+\$"
      fi
    fi
  else
    # jdk (head): tags are jdk-NN+BB on the default branch and on the jdkNN feature branches
    re='^jdk([0-9]+)$'
    if [[ "${BRANCH}" == "${SKARA_DEFAULT_BRANCH}" ]]; then
      BRANCH_CLASS="mainline"
      TAG_REGEX="^jdk-[0-9]+\\+[0-9]+\$"
    elif [[ "${BRANCH}" =~ $re ]]; then
      BRANCH_CLASS="head-feature"
      TAG_REGEX="^jdk-${BASH_REMATCH[1]}\\+[0-9]+\$"
    fi
  fi
}

# Print the name of the mirror release branch that is the partner of the current release branch
# for the given build tag, or nothing if the current branch has no partner. See the "Paired
# branches" section of TAG_MIRRORING_STRATEGY.md. The partner is derived from the branch class
# and the tag shape only, there are no hard coded repos or versions:
#   jdk (head)    master <-> jdkMM          for jdk-MM+BB
#   jdkMMu        master <-> jdkMM.0.VV     for jdk-MM.0.VV+BB
#   jdk8u         master <-> openjdk8uNN2   for jdk8uNN2-bBB (aarch32 adds -aarch32-<date>)
# CSPU and sub-update branches have no partner.
function partnerReleaseBranch() {
  local tag="$1" re
  case "${BRANCH_CLASS}" in
    update|head-feature)
      # a versioned branch is partnered with the default branch's release branch
      echo "release"
      ;;
    mainline)
      if [[ "${VERSION}" == "8" ]]; then
        re='^jdk8u([0-9]+)-b[0-9]+'
        if [[ "$tag" =~ $re ]]; then
          echo "release_openjdk8u${BASH_REMATCH[1]}"
        fi
      elif [[ -n "${VERSION}" ]]; then
        re='^jdk-([0-9]+\.0\.[0-9]+)\+[0-9]+$'
        if [[ "$tag" =~ $re ]]; then
          echo "release_jdk${BASH_REMATCH[1]}"
        fi
      else
        re='^jdk-([0-9]+)\+[0-9]+$'
        if [[ "$tag" =~ $re ]]; then
          echo "release_jdk${BASH_REMATCH[1]}"
        fi
      fi
      ;;
  esac
}

# Create the <tag>_adopt tag on the current release branch, and set ADOPT_TAG_CREATED.
# _adopt tagging is strict: if <tag>_adopt already exists the job fails, because it means the
# branch tag filters overlap. The one exception is the partner rule: the existing tag is
# accepted if it lives on the partner's release branch (origin/<partner>) and not on the
# current release branch. In that case the tag is not created again and the job continues.
# dev and dev_* branches are never consulted, they contain release and would always match.
function tagAdopt() {
  local tag="$1" message="$2"
  local adoptTag="${tag}_adopt"
  local partner

  ADOPT_TAG_CREATED=false
  if [ -z "$(git tag -l "$adoptTag")" ]; then
    git tag -a "$adoptTag" -m "$message" || exit 1
    ADOPT_TAG_CREATED=true
    return 0
  fi

  partner=$(partnerReleaseBranch "$tag")
  if [[ -n "$partner" ]] \
     && git rev-parse -q --verify "refs/remotes/origin/$partner" > /dev/null \
     && git merge-base --is-ancestor "refs/tags/$adoptTag" "refs/remotes/origin/$partner" \
     && ! git merge-base --is-ancestor "refs/tags/$adoptTag" "$RELEASE_BRANCH" ; then
    echo "Adopt tag ${adoptTag} already exists on partner branch origin/${partner}, not tagging it again on $RELEASE_BRANCH"
    return 0
  fi

  echo "ERROR: ${adoptTag} already exists but is not on this branch's partner (${partner:-none}), so the branch tag filters overlap"
  echo "Branches containing ${adoptTag}:"
  git branch -r --contains "refs/tags/$adoptTag" || true
  exit 1
}


# List the sorted (oldest first) build tags this branch is responsible for that are merged into
# the given ref. Prints nothing, and succeeds, if there are none: callers must check for that.
# (The filters below return 1 on empty input, which must not kill the job under pipefail.)
function listBuildTags() {
  git tag --merged "$1" | { grep -E "$TAG_REGEX" || true; } | { eval "$jdk_sort_tags_cmd" || true; }
}

# Merge master(New tagged builds only) into release branch as we build
# off release branch at the Adoptium JDK Build farm for release builds
# release branch contains patches that Adoptium JDK has beyond upstream OpenJDK tagged builds
function performMergeIntoReleaseFromMaster() {

  if [[ "${BRANCH_CLASS}" == "unknown" ]]; then
    echo "WARNING: upstream branch '$BRANCH' does not match any known branch naming pattern, so no release or dev branch is maintained for it"
    SKIP_RELEASE_AND_DEV=true
    return 0
  fi

  # Abort existing merge
  git merge --abort || true
  git reset --hard || true

  # Fetch latest and get latest master build tag
  git fetch --all --tags

  sortedBuildTags=$(listBuildTags origin/"$BRANCH")
  if [[ -z "$sortedBuildTags" ]]; then
    echo "No eligible build tags (matching $TAG_REGEX) on origin/$BRANCH yet, skipping release and dev branches for it"
    SKIP_RELEASE_AND_DEV=true
    return 0
  fi

  NEW_RELEASE_BRANCH_TAG=""
  if ! git checkout -f "$RELEASE_BRANCH" ; then
    if ! git rev-parse -q --verify "origin/$RELEASE_BRANCH" ; then
      currentBuildTag=$(echo "$sortedBuildTags" | tail -1)
      git checkout -b "$RELEASE_BRANCH" $currentBuildTag || exit 1
      # Remember the tag this new branch was created from so we can _adopt tag it after patching
      NEW_RELEASE_BRANCH_TAG="$currentBuildTag"
    else
      git checkout -b "$RELEASE_BRANCH" "origin/$RELEASE_BRANCH" || exit 1
    fi
  else
    git reset --hard "origin/$RELEASE_BRANCH" || echo "Not resetting as no upstream exists"
  fi

  # Apply Adoptium patches to release branch, gated on README.JAVASE not existing
  # (README.JAVASE is the Adoptium marker file — its absence means no patches have been applied yet)
  if [ ! -f "$WORKSPACE/$GITHUB_REPO/README.JAVASE" ]; then
    echo "Applying Adoptium patches for $GITHUB_REPO"

    # Step 1: Apply top-level patches, skipping any whose filename also exists in patches/<GITHUB_REPO>/
    # (repo-specific patches in the sub-folder take precedence and will be applied in step 2)
    for patchFile in "$PATCHES"*.patch; do
      [ -f "$patchFile" ] || continue
      patchName=$(basename "$patchFile")
      if [ -f "$PATCHES$GITHUB_REPO/$patchName" ]; then
        echo "Skipping top-level $patchName (overridden by patches/$GITHUB_REPO/$patchName)"
      else
        echo "Applying top-level patch: $patchName"
        if [[ ! -s "$patchFile" ]]; then
          echo "Skipping empty patch: $patchName"
          continue
        fi
        if ! git am --ignore-whitespace -3 "$patchFile" ; then
          if resolveGeneratedConfigureConflict ; then
            git am --continue || exit 1
          else
            git am --abort
            exit 1
          fi
        fi
      fi
    done

    # Step 2: Apply repo-specific patches from patches/<GITHUB_REPO>/ if that folder exists
    # Use --ignore-whitespace -3 for 3-way merge fallback, which handles context mismatches
    # when patches were generated against an older version of upstream files
    if [ -d "$PATCHES$GITHUB_REPO" ]; then
      for patchFile in "$PATCHES$GITHUB_REPO"/*.patch; do
        [ -f "$patchFile" ] || continue
        patchName=$(basename "$patchFile")
        echo "Applying repo-specific patch: $patchName"
        if [[ ! -s "$patchFile" ]]; then
          echo "Skipping empty patch: $patchName"
          continue
        fi
        if ! git am --ignore-whitespace -3 "$patchFile" ; then
          if resolveGeneratedConfigureConflict ; then
            git am --continue || exit 1
          else
            git am --abort
            exit 1
          fi
        fi
      done
    fi

    # For JDK 8 repos, regenerate generated-configure.sh after all patches have been applied.
    # company_name.patch modifies jdk-options.m4 but does not include the generated file
    # (unlike the alpine-jdk8u variant which bundles both). The JDK 8 configure wrapper
    # runs the checked-in generated script, so without regeneration --with-company-name
    # is unavailable at build time. autogen.sh is idempotent — if the patch already
    # included the generated file (e.g. alpine-jdk8u/0002) this produces no diff.
    if [[ "${VERSION}" == "8" ]]; then
      local AUTOGEN="common/autoconf/autogen.sh"
      local GENERATED="common/autoconf/generated-configure.sh"
      if [ -f "$AUTOGEN" ]; then
        echo "Regenerating $GENERATED after patch application"
        bash "$AUTOGEN" || exit 1
        if ! git diff --quiet "$GENERATED" ; then
          git add "$GENERATED"
          git commit --no-edit -m "Regenerate generated-configure.sh after Adoptium patches" || exit 1
          echo "Committed regenerated $GENERATED"
        else
          echo "$GENERATED already up to date, no commit needed"
        fi
      else
        echo "WARNING: $AUTOGEN not found — skipping $GENERATED regeneration"
      fi
    fi

    # If this is a brand new release branch, tag the base build tag with _adopt now that
    # patches have been applied — the merge loop below will find no new tags to process
    if [[ -n "$NEW_RELEASE_BRANCH_TAG" ]]; then
      echo "Tagging new $RELEASE_BRANCH base tag ${NEW_RELEASE_BRANCH_TAG}_adopt"
      tagAdopt "$NEW_RELEASE_BRANCH_TAG" "Merged ${NEW_RELEASE_BRANCH_TAG} into $RELEASE_BRANCH"
    fi
  else
    echo "README.JAVASE already exists — patches already applied, skipping"
  fi

  # Find the latest release tag that is not in releaseTagExcludeList
  sortedReleaseTags=$(listBuildTags "$RELEASE_BRANCH")
  currentReleaseTag=""
  for tag in $sortedReleaseTags; do
    skipThisTag=false
    # Check if tag is in the releaseTagExcludeList, if so it can't be the current tag
    if [ -n "${releaseTagExcludeList-}" ] ; then
      for skipTag in $releaseTagExcludeList; do
        if [ "x$tag" == "x$skipTag" ]; then
          echo "Skipping excluded tag $tag from current list"
          skipThisTag=true
        fi
      done
    fi
    if [[ "$skipThisTag" == false ]]; then
      currentReleaseTag="$tag"
    fi
  done

  echo "Current $RELEASE_BRANCH build tag: $currentReleaseTag"

  # Merge any new builds since current release build tag
  foundCurrentReleaseTag=false
  newAdoptTags=""
  for tag in $sortedBuildTags; do
    if [[ "$foundCurrentReleaseTag" == false ]]; then
      if [ "x$tag" == "x$currentReleaseTag" ]; then
        foundCurrentReleaseTag=true
      fi
    else
      mergeTag=true
      # Check if tag is in the releaseTagExcludeList, if so do not bring it into the release branch
      # and do not create an _adopt tag
      if [ -n "${releaseTagExcludeList-}" ] ; then
        for skipTag in $releaseTagExcludeList; do
          if [ "x$tag" == "x$skipTag" ]; then
           mergeTag=false
           echo "Skipping merge of excluded tag $tag"
          fi
        done
      fi
      if [[ "$mergeTag" == true ]]; then
        echo "Merging build tag $tag into $RELEASE_BRANCH branch"
        if ! git merge -m"Merging $tag into $RELEASE_BRANCH" $tag ; then
          if resolveGeneratedConfigureConflict ; then
            git commit --no-edit || exit 1
          else
            git merge --abort
            exit 1
          fi
        fi
        tagAdopt "$tag" "Merged $tag into $RELEASE_BRANCH"
        if [[ "$ADOPT_TAG_CREATED" == true ]]; then
          newAdoptTags="${newAdoptTags} ${tag}_adopt"
        fi
      fi
    fi
  done

  if git rev-parse -q --verify "origin/$RELEASE_BRANCH" ; then
    git --no-pager log --oneline "origin/$RELEASE_BRANCH..$RELEASE_BRANCH"
  fi

  # Find the latest and previous release tags that is not in releaseTagExcludeList
  sortedReleaseTags=$(listBuildTags "$RELEASE_BRANCH")
  prevReleaseTag=""
  currentReleaseTag=""
  for tag in $sortedReleaseTags; do
    skipThisTag=false
    # Check if tag is in the releaseTagExcludeList, if so it can't be the current tag
    if [ -n "${releaseTagExcludeList-}" ] ; then
      for skipTag in $releaseTagExcludeList; do
        if [ "x$tag" == "x$skipTag" ]; then
          echo "Skipping excluded tag $tag from current list"
          skipThisTag=true
        fi
      done
    fi
    if [[ "$skipThisTag" == false ]]; then
      prevReleaseTag="${currentReleaseTag}"
      currentReleaseTag="$tag"
    fi
  done
  echo "New $RELEASE_BRANCH build tag: $currentReleaseTag"

  git push --tags origin "$RELEASE_BRANCH" || exit 1

  # Check if the last two build tags are the same commit, and ensure we have tagged both _adopt tags
  if [ "x$prevReleaseTag" != "x" ]; then
    prevCommit=$(git rev-list -n 1 ${prevReleaseTag})
    currentCommit=$(git rev-list -n 1 ${currentReleaseTag})
    if [ "${prevCommit}" == "${currentCommit}" ] ; then
      echo "Current build tag commit is same as previous build tag commit: ${prevReleaseTag} == ${currentReleaseTag}"
      prevReleaseAdoptTag="${prevReleaseTag}_adopt"
      currentReleaseAdoptTag="${currentReleaseTag}_adopt"
      if [ "$(git tag -l "$prevReleaseAdoptTag")" != "" ]; then
        if [ "$(git tag -l "$currentReleaseAdoptTag")" == "" ]; then
          echo "Tagging new current $RELEASE_BRANCH tag ${currentReleaseAdoptTag} which is same commit as the previous ${prevReleaseAdoptTag}"
          git tag -a "${currentReleaseAdoptTag}" -m "Merged ${currentReleaseTag} into $RELEASE_BRANCH" || exit 1
          newAdoptTags="${newAdoptTags} ${currentReleaseAdoptTag}"
        fi
      fi
    fi
  fi

  # Ensure all new _adopt tags are pushed in case no new commits were pushed, eg.multiple tags on same commit
  for tag in $newAdoptTags; do
    echo "Pushing new tag: ${tag}"
    git push origin ${tag} || exit 1
  done
}

# Merge master(HEAD) into dev as we build off dev at the Adoptium JDK Build farm for Nightlies
# dev contains patches that Adoptium JDK has beyond upstream OpenJDK
function performMergeIntoDevFromMaster() {

  if [[ "${SKIP_RELEASE_AND_DEV}" == true ]]; then
    echo "Skipping dev branch for $BRANCH"
    return 0
  fi

  # Abort existing merge
  git merge --abort || true
  git reset --hard || true

  # Fetch latest and get latest master build tag
  git fetch --all --tags

  if ! git checkout -f "$DEV_BRANCH" ; then
    if ! git rev-parse -q --verify "origin/$DEV_BRANCH" ; then
      # Branch does not exist locally or on origin — create it from $BRANCH (upstream default,
      # already at latest HEAD from performMergeFromSkaraIntoGit), not from current HEAD
      # which will be RELEASE_BRANCH after performMergeIntoReleaseFromMaster()
      git checkout -b "$DEV_BRANCH" "$BRANCH" || exit 1
    else
      git checkout -b "$DEV_BRANCH" "origin/$DEV_BRANCH" || exit 1
    fi
  else
    # Only reset to origin/$DEV_BRANCH if it has been pushed there previously
    if git rev-parse -q --verify "origin/$DEV_BRANCH" ; then
      git reset --hard "origin/$DEV_BRANCH" || exit 1
    else
      echo "No origin/$DEV_BRANCH exists yet, skipping reset"
    fi
  fi

  currentDevTag=$(listBuildTags "$DEV_BRANCH" | tail -1)
  echo "Current $DEV_BRANCH build tag: $currentDevTag"

  # Merge master "HEAD"
  echo "Merging origin/$BRANCH HEAD into $DEV_BRANCH branch"
  if ! git merge -m"Merging origin/$BRANCH HEAD into $DEV_BRANCH" origin/"$BRANCH" ; then
    if resolveGeneratedConfigureConflict ; then
      git commit --no-edit || exit 1
    else
      git merge --abort
      exit 1
    fi
  fi

  # Merge latest patches from "release" branch
  if ! git merge -m"Merging latest patches from $RELEASE_BRANCH branch" "origin/$RELEASE_BRANCH" ; then
    if resolveGeneratedConfigureConflict ; then
      git commit --no-edit || exit 1
    else
      git merge --abort
      exit 1
    fi
  fi

  if git rev-parse -q --verify "origin/$DEV_BRANCH" ; then
    git --no-pager log --oneline "origin/$DEV_BRANCH..$DEV_BRANCH"
  fi

  currentDevTag=$(listBuildTags "$DEV_BRANCH" | tail -1)
  echo "New $DEV_BRANCH build tag: $currentDevTag"

  git push origin "$DEV_BRANCH" || exit 1
}

# When sourced (for example by the tests/ harness) only define the functions above
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

checkArgs $#

GITHUB_REPO="$1"

# alpine-jdk8u mirrors from the upstream jdk8u Skara repo
# SKARA_REPO_URL is an optional override of the upstream repo location, used by the tests/ harness
if [[ -n "${SKARA_REPO_URL:-}" ]]; then
  SKARA_REPO="${SKARA_REPO_URL}"
elif [[ "${GITHUB_REPO}" == "alpine-jdk8u" ]]; then
  SKARA_REPO="https://github.com/openjdk/jdk8u"
else
  SKARA_REPO="https://github.com/openjdk/${GITHUB_REPO}"
fi

# aarch32-port-jdk8u mirrors to the Adoptium repo named aarch32-jdk8u (without the "port-" prefix)
if [[ "${GITHUB_REPO}" == "aarch32-port-jdk8u" ]]; then
  REPO=${2:-"git@github.com:adoptium/aarch32-jdk8u"}
else
  REPO=${2:-"git@github.com:adoptium/$GITHUB_REPO"}
fi

# Determine the default branch of the upstream Skara repo via git ls-remote (no API token needed)
SKARA_DEFAULT_BRANCH=$(git ls-remote --symref "${SKARA_REPO}" HEAD | grep '^ref:' | sed 's|ref: refs/heads/||;s/[[:space:]].*//' | tr -d '[:space:]')
if [[ -z "${SKARA_DEFAULT_BRANCH}" ]]; then
  echo "ERROR: Could not determine default branch for ${SKARA_REPO} - git ls-remote --symref returned unexpected output"
  exit 1
fi
echo "Upstream default branch: ${SKARA_DEFAULT_BRANCH}"

BRANCH=${BRANCH:=${SKARA_DEFAULT_BRANCH}}

if [[ "${BRANCH}" == "${SKARA_DEFAULT_BRANCH}" ]]; then
  RELEASE_BRANCH="release"
  DEV_BRANCH="dev"
else
  RELEASE_BRANCH="release_${BRANCH}"
  DEV_BRANCH="dev_${BRANCH}"
fi

GITHUB_REPO_REMOVE_aarch32=${GITHUB_REPO#"aarch32"}
VERSION=${GITHUB_REPO_REMOVE_aarch32//[!0-9]/}
# Regex expands aarch32-jdk8u as 328
# Which tags a branch mirrors is decided by classifyBranch (see TAG_MIRRORING_STRATEGY.md)
SKIP_RELEASE_AND_DEV=false
classifyBranch
echo "Upstream branch $BRANCH is class '$BRANCH_CLASS', tag filter: ${TAG_REGEX:-<none>}"

# JDK11+ tag sorting:
# We use sort and tail to choose the latest tag in case more than one refers the same commit.
# Versions tags are formatted: jdk-V1[.V2[.V3[.V4[.V5[.V6[.V7]]]]]]+B (up to 7 version digits).
# Transform "-" to "." in tag so we can sort as: "jdk.V1[.V2...]+B"
# Pad with up to 6 zero fields (".0.0.0.0.0.0+") so single-digit versions (e.g. jdk-27)
# align up to 7 version components across fields 2 to 8.
# First, sort on build number (B):
jdk11plus_tag_sort1="sort -t+ -k2,2n"
# Second, (stable) sort on V1 through V7 (fields 2 through 8):
jdk11plus_tag_sort2="sort -t. -k2,2n -k3,3n -k4,4n -k5,5n -k6,6n -k7,7n -k8,8n"
# Ignore "..+0" branch fork point tags — these mark where the next version branched off master
# and are not real builds. Build tags for the next version (e.g. jdk-21.0.15+1) only appear on
# that new branch, never on master, so +0 is always the last visible tag for that version on
# master. Including it would advance currentReleaseTag past any not-yet-tagged current-version
# builds (e.g. jdk-21.0.14 GA), permanently locking them out of the merge loop.
jdk11plus_sort_tags_cmd="grep -v _adopt | grep -v -- '-ga$' | grep -v '\+0$' | sed 's/jdk-/jdk./g' | sed 's/+/.0.0.0.0.0.0+/g' | $jdk11plus_tag_sort1 | nl -n rz | $jdk11plus_tag_sort2 | sed 's/\.0\.0\.0\.0\.0\.0+/+/g' | cut -f2- | sed 's/jdk./jdk-/g'"

# JDK8 tag sorting:
# We use sort and tail to choose the latest tag in case more than one refers the same commit.
# Versions tags are formatted: jdkVu[.W]-bB; with V, W, B being numeric.
# First, sort on build number (B):
jdk8_tag_sort1="sort -tb -k2,2n"
# Second, (stable) sort on (V), (W)
jdk8_tag_sort2="sort -tu -k2,2n"
# Ignore "..-b00" branch fork point tags (same reasoning as jdk11+ above).
# Note: no "$" anchor — aarch32 tags embed -b00 mid-string, e.g. jdk8u504-b00-aarch32-20260731.
jdk8_sort_tags_cmd="grep -v _adopt | grep -v -- '-ga$' | grep -v '\-b00' | $jdk8_tag_sort1 | nl -n rz | $jdk8_tag_sort2  | cut -f2-"


if [[ "${VERSION}" == "8" ]]; then
  jdk_sort_tags_cmd="${jdk8_sort_tags_cmd}"
else
  jdk_sort_tags_cmd="${jdk11plus_sort_tags_cmd}"
fi

# For aarch32-port-jdk8u, the upstream Skara repo also contains non-aarch32 tags (inherited from
# the parent jdk8u repo). Prepend a filter so only tags containing "aarch32" are considered —
# this prevents non-aarch32 tags from being picked as the branch-point or merged into release/dev.
if [[ "${GITHUB_REPO}" == "aarch32-port-jdk8u" ]]; then
  jdk_sort_tags_cmd="grep 'aarch32' | ${jdk_sort_tags_cmd}"
fi

cloneGitHubRepo
addSkaralUpstream
performMergeFromSkaraIntoGit
performMergeIntoReleaseFromMaster
performMergeIntoDevFromMaster
