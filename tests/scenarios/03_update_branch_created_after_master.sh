#!/bin/bash
# Reverse order: Oracle merges the jdk-27.0.1 build stream into master first (so master is
# mirrored and tagged jdk-27.0.1+9_adopt on release), and only later creates the jdk27.0.1
# update branch at that same point. The new release_jdk27.0.1 branch is created from
# jdk-27.0.1+9, whose _adopt tag already exists on release (its partner).
#
# Expected: both runs succeed; exactly one jdk-27.0.1+9_adopt, on release.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk27u

up_build master jdk-27.0.1+7
up_push
mirror_ok master

up_build master jdk-27.0.1+8
up_build master jdk-27.0.1+9
up_push
mirror_ok master
assert_tag_on jdk-27.0.1+9_adopt release

# Two days later the update branch appears, at the same commit
up_branch jdk27.0.1 master
up_tag jdk-27.0.1-ga jdk27.0.1
up_push
mirror_ok jdk27.0.1

assert_branch_exists release_jdk27.0.1
assert_tag_on jdk-27.0.1+9 release_jdk27.0.1
assert_tag_on jdk-27.0.1+9_adopt release
assert_tag_not_on jdk-27.0.1+9_adopt release_jdk27.0.1
# -ga tags are never _adopt tagged
assert_no_tag jdk-27.0.1-ga_adopt

mirror_ok master
mirror_ok jdk27.0.1

echo "OK"
