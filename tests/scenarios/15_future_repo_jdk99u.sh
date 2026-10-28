#!/bin/bash
# A repo version that does not exist today (jdk99u) must behave exactly like jdk27u with no
# script change: no repo or version specific logic, only the generic jdkNNu naming.
#   - update branch jdk99.0.1 merged into master (partner rule)
#   - CSPU branch jdk99.0.1.0.2 merged into master (strict, belongs to its own release branch)
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk99u

up_build master jdk-99.0.1+7
up_push
mirror_ok master

up_branch jdk99.0.1 master
up_build jdk99.0.1 jdk-99.0.1+8
up_build jdk99.0.1 jdk-99.0.1+9
up_push
mirror_ok jdk99.0.1
assert_tag_on jdk-99.0.1+9_adopt release_jdk99.0.1

up_branch jdk99.0.1.0.2 master
up_build jdk99.0.1.0.2 jdk-99.0.1.0.2+1
up_build jdk99.0.1.0.2 jdk-99.0.1.0.2+2
up_push
mirror_ok jdk99.0.1.0.2
assert_tag_on jdk-99.0.1.0.2+2_adopt release_jdk99.0.1.0.2

up_merge master jdk99.0.1
up_merge master jdk99.0.1.0.2
up_push
mirror_ok master

assert_tag_on jdk-99.0.1+9 release
assert_tag_not_on jdk-99.0.1+9_adopt release
assert_tag_not_on jdk-99.0.1.0.2+2_adopt release

mirror_ok jdk99.0.1
mirror_ok jdk99.0.1.0.2
mirror_ok master

echo "OK"
