#!/usr/bin/env bash
# Runs inside the kernel VM. Mounts are privileged except rootless-inner;
# every R test runs as the unprivileged ubuntu user or a user-namespace root.
set -euo pipefail
expect=$1
phase=${2:-outer}
run_cases() {
  local layout=$1 home=$2
  findmnt "$home"
  for scenario in fresh preloaded hosted replaced; do
    if [[ "$phase" == rootless-inner ]]; then
      env RJE_JAVA_HOME_A="$home" RJE_OVERLAY_LAYOUT="$layout" RJE_OVERLAY_USERNS=1 \
        Rscript --vanilla tests-integration/overlay.R "$scenario"
    else
      runuser -u ubuntu -- env RJE_JAVA_HOME_A="$home" RJE_OVERLAY_LAYOUT="$layout" \
        Rscript --vanilla tests-integration/overlay.R "$scenario"
    fi
  done
}
if [[ "$phase" == rootless-inner ]]; then
  work=/home/ubuntu/overlay-rootless
  mkdir -p "$work"/{upper,work,merged}
  mount -t overlay overlay -o "lowerdir=/opt/overlay-lower,upperdir=$work/upper,workdir=$work/work,userxattr" "$work/merged"
  trap 'umount "$work/merged"' EXIT
  cat /proc/self/uid_map
  run_cases rootless "$work/merged"
  exit
fi
export RJE_OVERLAY_EXPECT="$expect"
mkdir -p /opt/overlay-lower /opt/jdk-b /opt/overlay-upper
cp -a "$JAVA_HOME/." /opt/overlay-lower/
cp -a "$JAVA_HOME/." /opt/jdk-b/
chown -R ubuntu:ubuntu /opt/overlay-lower
# A second real ext4 filesystem, not merely another directory on the same fs.
truncate -s 1G /opt/overlay-upper.img
mkfs.ext4 -q -F /opt/overlay-upper.img
mount -o loop /opt/overlay-upper.img /opt/overlay-upper
export RJE_JAVA_HOME_B=/opt/jdk-b
for layout in same cross-off cross-on; do
  upper=/opt/overlay-upper
  options=
  if [[ "$layout" == same ]]; then upper=/opt; fi
  if [[ "$layout" == cross-off ]]; then options=,xino=off; fi
  if [[ "$layout" == cross-on ]]; then options=,xino=on; fi
  work="$upper/rjava-$layout"
  mkdir -p "$work"/{upper,work,merged}
  chown -R ubuntu:ubuntu "$work"
  mount -t overlay overlay -o "lowerdir=/opt/overlay-lower,upperdir=$work/upper,workdir=$work/work$options" "$work/merged"
  run_cases "$layout" "$work/merged"
  umount "$work/merged"
done
# Configure the isolated VM to allow the user namespaces being tested.
if [[ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]; then
  sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
fi
if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
  sysctl -w kernel.unprivileged_userns_clone=1
fi
runuser -u ubuntu -- unshare --user --map-root-user --mount --propagation private \
  bash tests-integration/overlay-layouts.sh "$expect" rootless-inner
umount /opt/overlay-upper
