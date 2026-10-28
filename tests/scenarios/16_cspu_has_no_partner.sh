#!/bin/bash
# A CSPU / sub-update branch (four or more version components) has no partner. If the _adopt tag
# of its base tag already exists on release, that is an overlap and the job must fail.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk27u

up_build master jdk-27.0.1+7
up_push
mirror_ok master

up_branch jdk27.0.1.0.2 master
up_build jdk27.0.1.0.2 jdk-27.0.1.0.2+1
up_push

mirror_plant_adopt_tag jdk-27.0.1.0.2+1_adopt release

mirror_fails jdk27.0.1.0.2

echo "OK"
