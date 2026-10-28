#!/bin/bash
# A CSPU branch (jdk11.0.32.1) is created from a master tag, builds and a GA are tagged on the
# branch, and the branch is merged into master. The CSPU tags have four version components, so
# they belong to release_jdk11.0.32.1 only and must not be mirrored from master.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk11u

up_build master jdk-11.0.32+7
up_build master jdk-11.0.32+8
up_push
mirror_ok master

up_branch jdk11.0.32.1 master
up_build jdk11.0.32.1 jdk-11.0.32.1+0
up_build jdk11.0.32.1 jdk-11.0.32.1+1
up_build jdk11.0.32.1 jdk-11.0.32.1+2
up_tag jdk-11.0.32.1-ga jdk11.0.32.1
up_push
mirror_ok jdk11.0.32.1

up_merge master jdk11.0.32.1
up_build master jdk-11.0.33+1
up_push
mirror_ok master

assert_tag_on jdk-11.0.32.1+2_adopt release_jdk11.0.32.1
assert_tag_not_on jdk-11.0.32.1+2_adopt release
assert_no_tag jdk-11.0.32.1+1_adopt
assert_tag_exists jdk-11.0.33+1_adopt
assert_tag_on jdk-11.0.33+1_adopt release
assert_no_tag jdk-11.0.32.1-ga_adopt

mirror_ok jdk11.0.32.1
mirror_ok master

echo "OK"
