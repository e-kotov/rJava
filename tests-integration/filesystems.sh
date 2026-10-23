#!/usr/bin/env bash
# Real ext4/btrfs loop mounts on a GitHub worker; all loader/R tests are
# unprivileged. The old loader must reproduce the btrfs failure first.
set -euo pipefail
fs=$1
work="$RUNNER_TEMP/rjava-$fs"
mountpoint="$work/mount"
mkdir -p "$mountpoint"
truncate -s 3G "$work/disk.img"
if [[ "$fs" == btrfs ]]; then
  sudo mkfs.btrfs -q -f "$work/disk.img"
else
  sudo mkfs.ext4 -q -F "$work/disk.img"
fi
sudo mount -o loop "$work/disk.img" "$mountpoint"
trap 'sudo umount "$mountpoint"' EXIT
sudo chown "$(id -u):$(id -g)" "$mountpoint"
[[ "$(findmnt -n -o FSTYPE --target "$mountpoint")" == "$fs" ]]
if [[ "$fs" == btrfs ]]; then btrfs subvolume create "$mountpoint/jdks"; else mkdir "$mountpoint/jdks"; fi
# Replacement scenarios hard-link B into A's directory. Both homes must
# share a subvolume; cross-subvolume identity is tested separately below.
mkdir "$mountpoint/jdks/jdk-a" "$mountpoint/jdks/jdk-b"
cp -a "$RJE_JAVA_HOME_A/." "$mountpoint/jdks/jdk-a/"
cp -a "$RJE_JAVA_HOME_B/." "$mountpoint/jdks/jdk-b/"
export RJE_JAVA_HOME_A="$mountpoint/jdks/jdk-a" RJE_JAVA_HOME_B="$mountpoint/jdks/jdk-b"
lib_a="$RJE_JAVA_HOME_A/lib/server/libjvm.so"
lib_b="$RJE_JAVA_HOME_B/lib/server/libjvm.so"
stat -Lc 'file=%n device=%d inode=%i' "$lib_a" "$lib_b"
cc -O2 -Wall -Wextra -Werror -Isrc tests-integration/identity.c src/djni.c -ldl -o "$work/identity"
git show cd6bbe5ef94172ac85e9c44ae8930d0ce4bf40b2:src/djni.c > "$work/old-djni.c"
cc -O2 -Isrc tests-integration/identity.c "$work/old-djni.c" -ldl -o "$work/old-identity"
old_mode=current
if [[ "$fs" == btrfs ]]; then old_mode=old-btrfs; fi
"$work/old-identity" "$lib_a" "$lib_b" "$old_mode"
"$work/identity" "$lib_a" "$lib_b" current
if [[ "$fs" == btrfs ]]; then
  # Distinct subvolumes can have the same inode numbers. Equal inodes alone
  # must not select a different subvolume's file, even with identical bytes.
  btrfs subvolume snapshot "$mountpoint/jdks" "$mountpoint/jdk-shadow"
  shadow="$mountpoint/jdk-shadow/jdk-a/lib/server/libjvm.so"
  stat -Lc 'snapshot=%n device=%d inode=%i' "$shadow"
  "$work/identity" "$lib_a" "$shadow" current
fi
run() { echo "::group::$fs $*"; Rscript --vanilla tests-integration/deferred.R "$@"; echo '::endgroup::'; }
for scenario in select preloaded; do run "$scenario"; done
run preloaded global
run hosted explicit
run alias link
run alias spelling
run renamed hardlink
run replaced deleted
run replaced replaced
run hosted replaced
echo "PASS $fs native and R integration"
