.PHONY: genconfig apply diff upgrade encrypt decrypt pxe-assets pxe-sync-configs

genconfig:
	talhelper genconfig -c talconfig.yaml

diff:
	talhelper genconfig -c talconfig.yaml --dry-run

apply:
	talhelper gencommand apply | bash

upgrade:
	bash scripts/upgrade-staged.sh

pxe-assets:
	@mkdir -p pxe/assets
	gh release download -R Tsuguya-HC/talos-custom-build \
	  -p vmlinuz-amd64 -p initramfs-amd64.xz -D pxe/assets --clobber
	mv pxe/assets/vmlinuz-amd64 pxe/assets/vmlinuz
	mv pxe/assets/initramfs-amd64.xz pxe/assets/initramfs.xz

pxe-sync-configs: genconfig
	bash pxe/scripts/sync-configs.sh
