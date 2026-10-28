#!/bin/bash
# A brand new CSPU branch only has its jdk-11.0.32.1+0 fork point tag (which is never a real
# build), so there are no eligible tags for it. The job must succeed and skip the release and
# dev steps for it rather than die in the tag filter under "set -e / pipefail".
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk11u

up_build master jdk-11.0.32+7
up_build master jdk-11.0.32+8
up_push
mirror_ok master

up_branch jdk11.0.32.1 master
up_build jdk11.0.32.1 jdk-11.0.32.1+0
up_push
mirror_ok jdk11.0.32.1

# The upstream branch is still mirrored, but there is no release or dev branch for it
assert_branch_exists jdk11.0.32.1
assert_no_branch release_jdk11.0.32.1
assert_no_branch dev_jdk11.0.32.1
assert_no_tag jdk-11.0.32.1+0_adopt

echo "OK"
