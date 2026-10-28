#!/bin/bash
# jdk8u: master is partnered with an openjdk8uNN2 update branch (version ends in 2) for
# jdk8uNN2-bBB tags, in both orders:
#   - openjdk8u512 is mirrored first and merged into master later (like jdk27u scenario 02)
#   - openjdk8u522 is created after master has already mirrored its tags (like scenario 03)
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
setup_scenario jdk8u

up_build master jdk8u502-b01
up_push
mirror_ok master

# update branch first, merged later
up_branch openjdk8u512 master
up_build openjdk8u512 jdk8u512-b01
up_build openjdk8u512 jdk8u512-b02
up_push
mirror_ok openjdk8u512
assert_tag_on jdk8u512-b02_adopt release_openjdk8u512

up_merge master openjdk8u512
up_push
mirror_ok master
assert_tag_on jdk8u512-b02 release
assert_tag_not_on jdk8u512-b02_adopt release

# master first, update branch created later at the same point
up_build master jdk8u522-b01
up_build master jdk8u522-b02
up_push
mirror_ok master
assert_tag_on jdk8u522-b02_adopt release

up_branch openjdk8u522 master
up_push
mirror_ok openjdk8u522
assert_tag_on jdk8u522-b02 release_openjdk8u522
assert_tag_not_on jdk8u522-b02_adopt release_openjdk8u522

mirror_ok master
mirror_ok openjdk8u512
mirror_ok openjdk8u522

echo "OK"
