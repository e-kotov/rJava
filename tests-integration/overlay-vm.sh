#!/usr/bin/env bash
# Boot a real kernel: containers would reuse the Actions runner's kernel.
set -euo pipefail
release=$1
expect=$2
work="$RUNNER_TEMP/overlay-$release"
mkdir -p "$work"
case "$release" in
  jammy) version=22.04 ;;
  noble) version=24.04 ;;
  *) exit 2 ;;
esac
image="ubuntu-$version-server-cloudimg-amd64.img"
base="https://cloud-images.ubuntu.com/releases/$release/release"
curl --fail --location --retry 3 "$base/$image" -o "$work/$image"
curl --fail --location --retry 3 "$base/SHA256SUMS" -o "$work/SHA256SUMS"
(cd "$work" && awk -v image="$image" '$2 == image || $2 == "*" image' SHA256SUMS > selected.sha256 && test -s selected.sha256 && sha256sum -c selected.sha256)
qemu-img resize "$work/$image" 16G
ssh-keygen -t ed25519 -N '' -f "$work/key"
cat > "$work/user-data" <<CONFIG
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$work/key.pub")
CONFIG
printf 'instance-id: rjava-%s\nlocal-hostname: rjava\n' "$release" > "$work/meta-data"
cloud-localds "$work/seed.img" "$work/user-data" "$work/meta-data"
sudo qemu-system-x86_64 -accel kvm -cpu host -smp 2 -m 3072 \
  -drive "file=$work/$image,if=virtio,format=qcow2" \
  -drive "file=$work/seed.img,if=virtio,format=raw" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=net0 \
  -display none -serial "file:$work/serial.log" -daemonize -pidfile "$work/qemu.pid"
trap 'sudo kill "$(cat "$work/qemu.pid")" || true' EXIT
ssh_opts=(-i "$work/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
ready=false
for attempt in {1..60}; do
  if ssh "${ssh_opts[@]}" -p 2222 ubuntu@127.0.0.1 true 2>/dev/null; then ready=true; break; fi
  sleep 5
done
if ! "$ready"; then cat "$work/serial.log"; exit 1; fi
# Include the checked-out REngine submodule, without Git metadata or VM files.
tar --exclude=.git -czf "$work/source.tar.gz" .
scp "${ssh_opts[@]}" -P 2222 "$work/source.tar.gz" ubuntu@127.0.0.1:source.tar.gz
ssh "${ssh_opts[@]}" -p 2222 ubuntu@127.0.0.1 "sudo bash -s -- '$expect'" <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait
apt-get update -qq
apt-get install -y --no-install-recommends r-base-dev openjdk-17-jdk-headless make g++ unzip zip
mkdir /home/ubuntu/source
cd /home/ubuntu/source
tar -xzf ../source.tar.gz
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
R CMD javareconf
sh mkdist > /home/ubuntu/build.log 2>&1 || { cat /home/ubuntu/build.log; exit 1; }
mkdir /opt/rjava-lib
R CMD INSTALL --library=/opt/rjava-lib ../rJava_*.tar.gz
export R_LIBS=/opt/rjava-lib
mkdir -p /opt/overlay/{lower,upper,work,merged} /opt/jdk-b
cp -a "$JAVA_HOME/." /opt/overlay/lower/
cp -a "$JAVA_HOME/." /opt/jdk-b/
mount -t overlay overlay -o lowerdir=/opt/overlay/lower,upperdir=/opt/overlay/upper,workdir=/opt/overlay/work /opt/overlay/merged
findmnt /opt/overlay/merged
uname -a
export RJE_JAVA_HOME_A=/opt/overlay/merged RJE_JAVA_HOME_B=/opt/jdk-b RJE_OVERLAY_EXPECT="$1"
mkdir /tmp/jvmhost
cp tests-integration/jvmhost.c /tmp/jvmhost/
(cd /tmp/jvmhost && PKG_CPPFLAGS=-I/home/ubuntu/source/src R CMD SHLIB jvmhost.c)
export RJE_JVMHOST=/tmp/jvmhost/jvmhost.so
for scenario in fresh preloaded hosted replaced; do
  Rscript --vanilla tests-integration/overlay.R "$scenario"
done
GUEST
