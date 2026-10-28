#!/bin/bash
# jdk (head) repo. master is partnered with the jdkMM feature branch for jdk-MM+BB tags.
#
# jdk-27+25 is tagged on master and mirrored (jdk-27+25_adopt on release). jdk27 is then forked
# at that point, master moves on to jdk-28, and later the jdk27 branch is first mirrored.
# release_jdk27 is created from jdk-27+25, whose _adopt tag already exists on release (the
# partner), which must be accepted. Builds on jdk27 afterwards are mirrored from jdk27.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk

up_build master jdk-27+24
up_build master jdk-27+25
up_push
mirror_ok master
assert_tag_on jdk-27+25_adopt release

up_branch jdk27 master
up_build master jdk-28+1
up_build master jdk-28+2
up_push
mirror_ok master
assert_tag_on jdk-28+2_adopt release

mirror_ok jdk27
assert_branch_exists release_jdk27
assert_tag_on jdk-27+25_adopt release
assert_tag_not_on jdk-28+2 release_jdk27

up_build jdk27 jdk-27+26
up_push
mirror_ok jdk27
assert_tag_on jdk-27+26_adopt release_jdk27
assert_tag_not_on jdk-27+26_adopt release

mirror_ok master
mirror_ok jdk27

echo "OK"
