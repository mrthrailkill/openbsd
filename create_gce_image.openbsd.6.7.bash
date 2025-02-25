#!/bin/bash

# Script to create an OpenBSD image for GCE.
# Run on a Linux host with Qemu installed.

# Copyright 2020 Google LLC

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

readonly version="67"
readonly longversion="6.7"
readonly disk="/tmp/disk.raw"
readonly authorized_keys="root/.ssh/authorized_keys"
readonly root_password=$(openssl rand 20 | hexdump -e '20/1 "%02x"')
readonly tar_file="openbsd${version}-amd64-gce.tar.gz"

# User of this script MUST provide a ssh authorized_keys file
if ! [ -e ${authorized_keys} ]; then
  echo "You must create ${authorized_keys}"
  exit 1
fi

# Download kernel, sets, etc. from ftp.usa.openbsd.org
if ! [ -e install${version}.iso ]; then
  curl -O ftp://ftp.usa.openbsd.org/pub/OpenBSD/snapshots/amd64/install${version}.iso
fi

# TODO: Download and save bash, curl, and their dependencies too?
# Currently we download them from the network during the install process.

# Create custom site${version}.tgz set.
mkdir -p etc
cat >install.site <<EOF
#!/bin/sh
env PKG_PATH=ftp://ftp.usa.openbsd.org/pub/OpenBSD/snapshots/packages/amd64 pkg_add -iv bash curl
echo "ignore classless-static-routes;" >> /etc/dhclient.conf
chown -R root:wheel /etc/rc.local /etc/ssh/sshd_config /root/.ssh
chmod 640 /root/.ssh/authorized_keys
EOF
chmod +x install.site
tar -zcvf site${version}.tgz install.site etc/ssh/sshd_config root/.ssh/authorized_keys

# Hack install CD a bit.
echo 'set tty com0' > boot.conf
dd if=/dev/urandom of=random.seed bs=4096 count=1
cp install${version}.iso install${version}-patched.iso
growisofs -M install${version}-patched.iso -l -R -graft-points \
  /${longversion}/amd64/site${version}.tgz=site${version}.tgz \
  /etc/boot.conf=boot.conf \
  /etc/random.seed=random.seed

# Initialize disk image.
rm -f ${disk}
qemu-img create -f raw ${disk} 10G

# Run the installer to create the disk image.
expect <<EOF
spawn qemu-system-x86_64 -nographic -smp 2 -drive if=virtio,file=${disk} -cdrom install${version}-patched.iso -net nic,model=virtio -net user -boot once=d

expect "boot>"
send "\n"

# Need to wait for the kernel to boot.
expect -timeout 600 "\(I\)nstall, \(U\)pgrade, \(A\)utoinstall or \(S\)hell\?"
send "i\n"

expect "Terminal type\?"
send "vt220\n"

expect "System hostname\?"
send "openbsd\n"

expect "Which network interface do you wish to configure\?"
send "vio0\n"

expect "DNS domain name\?"
send "\n"

expect "IPv4 address for vio0\?"
send "dhcp\n"

expect "IPv6 address for vio0\?"
send "\n"

expect "IPv6 prefix length for vio0\?"
send "\n"

expect "Which network interface do you wish to configure\?"
send "done\n"

expect "DNS domain name\?"
send "\n"

expect "Password for root account\?"
send "${root_password}\n"

expect "Password for root account\?"
send "${root_password}\n"

expect "Start sshd\(8\) by default\?"
send "yes\n"

expect "Do you expect to run the X Window System\?"
send "no\n"

expect "Change the default console to com0\?"
send "yes\n"

expect "Which speed should com0 use\?"
send "115200\n"

expect "Setup a user\?"
send "n\n"

expect "Allow root ssh login\?"
send "prohibit-password\n"

expect "What timezone are you in\?"
send "Australia/Sydney\n"

expect "Which disk is the root disk\?"
send "sd0\n"

expect "Use \(W\)hole disk MBR, whole disk \(G\)PT or \(E\)dit\?"
send "W\n"

expect "Use \(A\)uto layout, \(E\)dit auto layout, or create \(C\)ustom layout\?"
send "C\n"

expect "> "
send "z\n"

expect "> "
send "a b\n"
expect "offset: "
send "\n"
expect "size: "
send "1G\n"
expect "FS type: "
send "swap\n"

expect "> "
send "a a\n"
expect "offset: "
send "\n"
expect "size: "
send "\n"
expect "FS type: "
send "4.2BSD\n"
expect "mount point: "
send "/\n"

expect "> "
send "w\n"
expect "> "
send "q\n"

expect "Location of sets\?"
send "cd0\n"

expect "Pathname to the sets\?"
send "${longversion}/amd64\n"

expect "Set name\(s\)\?"
send "+*\n"

expect "Set name\(s\)\?"
send " -x*\n"

expect "Set name\(s\)\?"
send " -game*\n"

expect "Set name\(s\)\?"
send " -man*\n"

expect "Set name\(s\)\?"
send "done\n"

expect "Directory does not contain SHA256\.sig\. Continue without verification\?"
send "yes\n"

# Need to wait for previous sets to unpack.
expect -timeout 600 "Location of sets\?"
send "done\n"

# Need to wait for install.site to install curl.
expect -timeout 600 "CONGRATULATIONS!"

expect "# "
send "halt\n"

expect "Please press any key to reboot.\n"
send "\n"

expect "boot>"
send "\n"

expect "login:"
EOF

# Create Compute Engine disk image.
echo "Zipping ${disk}... (this may take a while)"
tar -Szcf ${tar_file} -C /tmp disk.raw

cat <<EOF
Done.

GCE image is ${tar_file}

Generated root password is: ${root_password}

Next steps:
1. Upload file to GCS:
  gsutil cp ${tar_file} gs://GCS_BUCKET/
2. Create image from file:
  gcloud compute --project PROJECT images create openbsd-${version} --source-uri https://storage.googleapis.com/GCS_BUCKET/${tar_file}
3. Create VM from image.
4. SSH directly to instance using external IP, not using the gcloud command.
  ssh -l root EXTERNAL_IP
EOF
