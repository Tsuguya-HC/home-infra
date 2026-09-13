.PHONY: genconfig diff apply upgrade pxe-assets pxe-sync-configs

# Render clusterconfig/<host>.yaml for every node (secrets come from 1Password).
genconfig:
	bash scripts/genconfig.sh

# Ask each node what would change. The node diffs against its running config, so this
# is the only comparison that means anything (a diff against files on disk only tells
# you what the generator changed since last time).
diff: genconfig
	bash scripts/apply.sh --dry-run

apply: genconfig
	bash scripts/apply.sh

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
