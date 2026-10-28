#!/bin/bash
# An update branch tags its builds and a GA but Oracle never merges it into master.
# The tags must still be mirrored, from the update branch, and must not appear under master.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk27u

up_build master jdk-27.0.1+7
up_push
mirror_ok master

up_branch jdk27.0.2 master
up_build jdk27.0.2 jdk-27.0.2+1
up_build jdk27.0.2 jdk-27.0.2+2
up_tag jdk-27.0.2-ga jdk27.0.2
up_push

mirror_ok jdk27.0.2
mirror_ok master

assert_branch_exists release_jdk27.0.2
assert_tag_exists jdk-27.0.2+2_adopt
assert_tag_on jdk-27.0.2+2_adopt release_jdk27.0.2
assert_tag_not_on jdk-27.0.2+2_adopt release
assert_no_tag jdk-27.0.2-ga_adopt

echo "OK"
