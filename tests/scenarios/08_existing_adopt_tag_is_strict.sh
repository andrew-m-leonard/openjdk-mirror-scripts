#!/bin/bash
# _adopt tagging stays strict outside the partner rule.
#
# (a) jdk-27.0.1+8_adopt already exists on an unrelated branch: master must fail.
# (b) jdk-27.0.1+9_adopt already exists on release itself (the branch being processed) although
#     the upstream tag has not been merged there: master must fail.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# (a)
setup_scenario jdk27u
up_build master jdk-27.0.1+7
up_push
mirror_ok master
mirror_plant_adopt_tag jdk-27.0.1+8_adopt some-unrelated-branch
up_build master jdk-27.0.1+8
up_push
mirror_fails master
rm -rf "$T"

# (b)
setup_scenario jdk27u
up_build master jdk-27.0.1+7
up_push
mirror_ok master
mirror_plant_adopt_tag jdk-27.0.1+9_adopt release
up_build master jdk-27.0.1+9
up_push
mirror_fails master

echo "OK"
