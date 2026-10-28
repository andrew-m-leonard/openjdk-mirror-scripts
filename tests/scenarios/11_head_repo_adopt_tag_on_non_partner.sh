#!/bin/bash
# jdk (head) repo, negative case: the base tag of a new release_jdk27 branch already has an
# _adopt tag, but on a branch that is not the partner (release). That means the filters overlap
# or something is wrong, so the job must fail.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk

up_build master jdk-27+24
up_push
mirror_ok master

up_build master jdk-27+25
up_branch jdk27 master
up_push

mirror_plant_adopt_tag jdk-27+25_adopt some-unrelated-branch

mirror_fails jdk27

echo "OK"
