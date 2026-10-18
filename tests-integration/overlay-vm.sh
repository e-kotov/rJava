#!/usr/bin/env bash
# Boot a real kernel: containers would reuse the Actions runner's kernel.
set -euo pipefail
release=$1
expect=$2
work="$RUNNER_TEMP/overlay-$release"
mkdir -p "$work"
case "$release" in
  jammy) version=22.04; snapshot=20261004; image_sha=012d81fade7e8ff4428fc35dfeee711d66d1f47d5ea9c5c8ced96a85b959835c ;;
  noble) version=24.04; snapshot=20261017; image_sha=04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94 ;;
  *) exit 2 ;;
esac
image="ubuntu-$version-server-cloudimg-amd64.img"
base="https://cloud-images.ubuntu.com/releases/$release/release-$snapshot"
curl --fail --location --retry 3 "$base/$image" -o "$work/$image"
printf '%s  %s\n' "$image_sha" "$image" > "$work/selected.sha256"
(cd "$work" && sha256sum -c selected.sha256)
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
sudo chmod a+r "$work/qemu.pid" "$work/serial.log"
trap 'sudo kill "$(cat "$work/qemu.pid")" || true' EXIT
ssh_opts=(-i "$work/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
wait_for_ssh() {
  local previous_boot=${1:-} boot
  for _attempt in {1..60}; do
    if boot=$(ssh "${ssh_opts[@]}" -p 2222 ubuntu@127.0.0.1 cat /proc/sys/kernel/random/boot_id 2>/dev/null); then
      if [[ -n "$boot" && "$boot" != "$previous_boot" ]]; then return 0; fi
    fi
    sleep 5
  done
  cat "$work/serial.log"
  return 1
}
wait_for_ssh
if [[ "$expect" == legacy ]]; then
  # Current distro 5.15 kernels can carry overlayfs fixes. Also boot a frozen
  # pre-6.8 mainline build, so the ambiguous-identity case is really exercised.
  mainline=https://kernel.ubuntu.com/mainline/v6.1/amd64
  kernel_version=6.1.0-060100
  kernel_build=6.1.0-060100.202303090726
  packages=("linux-image-unsigned-${kernel_version}-generic_${kernel_build}_amd64.deb"
            "linux-modules-${kernel_version}-generic_${kernel_build}_amd64.deb")
  for package in "${packages[@]}"; do
    curl --fail --location --retry 3 "$mainline/$package" -o "$work/$package"
  done
  # SHA256 values from the release's CHECKSUMS, pinned with the package names.
  cat > "$work/kernel.sha256" <<SUMS
178f3cdfd9bd587a77c8b0efae050cfa98718dec51dce1e98b9530f6de5185d5  ${packages[0]}
ef4cf195e9e6840318e7fe9227d4ddccaf44ce44f0324d5dbd418ecaa72dc2d4  ${packages[1]}
SUMS
  (cd "$work" && sha256sum -c kernel.sha256)
  scp "${ssh_opts[@]}" -P 2222 "${packages[@]/#/$work/}" ubuntu@127.0.0.1:
  previous_boot=$(ssh "${ssh_opts[@]}" -p 2222 ubuntu@127.0.0.1 cat /proc/sys/kernel/random/boot_id)
  ssh "${ssh_opts[@]}" -p 2222 ubuntu@127.0.0.1 'set -e; cloud-init status --wait || test "$?" -eq 2; sudo dpkg -i linux-modules-*.deb linux-image-*.deb; sudo systemd-run --on-active=3s /sbin/reboot'
  wait_for_ssh "$previous_boot"
  ssh "${ssh_opts[@]}" -p 2222 ubuntu@127.0.0.1 'test "$(uname -r)" = 6.1.0-060100-generic'
fi
# Include the checked-out REngine submodule, without Git metadata or VM files.
tar --exclude=.git -czf "$work/source.tar.gz" .
scp "${ssh_opts[@]}" -P 2222 "$work/source.tar.gz" ubuntu@127.0.0.1:source.tar.gz
ssh "${ssh_opts[@]}" -p 2222 ubuntu@127.0.0.1 "sudo bash -s -- '$expect'" <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cloud-init status --wait || [[ $? == 2 ]]
apt-get update -qq
apt-get install -y --no-install-recommends r-base-dev openjdk-17-jdk-headless libtirpc-dev libicu-dev e2fsprogs util-linux make g++ unzip zip
mkdir /home/ubuntu/source
cd /home/ubuntu/source
tar -xzf ../source.tar.gz
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
R CMD javareconf
sh mkdist > /home/ubuntu/build.log 2>&1 || { cat /home/ubuntu/build.log; exit 1; }
mkdir /opt/rjava-lib
R CMD INSTALL --library=/opt/rjava-lib ../rJava_*.tar.gz
export R_LIBS=/opt/rjava-lib
uname -a
mkdir /tmp/jvmhost
cp tests-integration/jvmhost.c /tmp/jvmhost/
(cd /tmp/jvmhost && PKG_CPPFLAGS=-I/home/ubuntu/source/src R CMD SHLIB jvmhost.c)
export RJE_JVMHOST=/tmp/jvmhost/jvmhost.so
bash tests-integration/overlay-layouts.sh "$1"
GUEST
