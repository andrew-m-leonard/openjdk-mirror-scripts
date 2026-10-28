#!/bin/bash
# The original failure: jdk-27.0.1+9 is tagged on the upstream update branch jdk27.0.1,
# which is later merged into master. The Jenkinsfile mirrors the update branch first,
# then master, and the second _adopt tagging of jdk-27.0.1+9 used to fail the job.
#
# Expected: both runs succeed; exactly one jdk-27.0.1+9_adopt, on release_jdk27.0.1.
# master/release still merges the upstream tag but does not carry a second _adopt tag.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk27u

up_build master jdk-27.0.1+7
up_push
mirror_ok master

up_branch jdk27.0.1 master
up_build jdk27.0.1 jdk-27.0.1+8
up_build jdk27.0.1 jdk-27.0.1+9
up_push

# The Jenkinsfile mirrors non-default branches first, then the default branch
mirror_ok jdk27.0.1
assert_tag_exists jdk-27.0.1+9_adopt
assert_tag_on jdk-27.0.1+9_adopt release_jdk27.0.1

# Oracle merges the update branch into master
up_merge master jdk27.0.1
up_push
mirror_ok master

assert_tag_on jdk-27.0.1+9 release
assert_tag_exists jdk-27.0.1+8_adopt
assert_tag_on jdk-27.0.1+8_adopt release
assert_tag_on jdk-27.0.1+9_adopt release_jdk27.0.1
assert_tag_not_on jdk-27.0.1+9_adopt release

# A further run of each branch is a no-op
mirror_ok jdk27.0.1
mirror_ok master

echo "OK"
