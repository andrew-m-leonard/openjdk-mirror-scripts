#!/bin/bash
# An upstream branch whose name matches none of the known patterns (a port, a project or an
# experimental branch) is still rebased and pushed to the mirror, but gets no release or dev
# branch and no _adopt tags. The job does not fail.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk21u

up_build master jdk-21.0.32+7
up_push
mirror_ok master

up_branch some-project master
up_build some-project jdk-21.0.32+8
up_push
mirror_ok some-project

assert_branch_exists some-project
assert_no_branch release_some-project
assert_no_branch dev_some-project
assert_no_tag jdk-21.0.32+8_adopt

echo "OK"
