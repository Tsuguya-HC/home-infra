# home-infra

Talos Linux ノード設定。生成器は持たず、`talosctl` だけで machine config を組み立てる（上流の
[reproducible machine configuration](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/reproducible-machine-configuration) の形）。

## 構成

| ファイル | 説明 |
|---------|------|
| `cluster.yaml` | クラスタ名 / endpoint / Talos・Kubernetes の版 / installer image（Renovate が版を上げる） |
| `nodes.yaml` | ノード一覧（host / ip / role / mac） |
| `patches/all/` | 全ノードに当てる patch |
| `patches/controlplane/`, `patches/worker/` | ロール別 patch |
| `patches/node/<host>.yaml` | ノード別 patch（install disk、hostname、network） |
| `scripts/genconfig.sh` | `gen config` → `machineconfig patch` → `validate --strict` |
| `clusterconfig/` | 生成物 `<host>.yaml`（.gitignore 済み、secrets 入り） |

patch は `all/` → `<role>/` → `node/` の順、ディレクトリ内はファイル名順に当たる。1 ファイルに
v1alpha1 ドキュメントは 1 つまで（別 kind のドキュメントは `---` で並べてよい）。JSON6902 patch は
マルチドキュメント設定では使えない。

## Secrets

`talosctl gen secrets` 形式のバンドルは 1Password の `home-cluster` vault に Document item
`talos-secrets-bundle` として置く。git には一切入れない。`make genconfig` が `op document get` で
一時ファイルに落として `--with-secrets` に渡し、終了時に消す。

CI は秘密を持たず、`talosctl gen secrets` の使い捨てバンドルで生成して validate する。

## ワークフロー

```bash
# 1. patches/ や cluster.yaml を編集

# 2. 生成 + validate
make genconfig

# 3. 各ノードに dry-run して差分を見る（ノードが稼働中の設定と比較する）
make diff

# 4. 適用
make apply
```

`talosctl` は `~/.talos/config`（os:admin、endpoints は CP 直接 IP）を使う。

## クラスタ構成

| ロール | ホスト名 | IP | HW | Disk |
|--------|----------|-----|-----|------|
| CP | cp-13/cp-11/cp-12 | .230/.231/.232 | AOOSTAR N1 Pro (N150) | SATA M.2 (ASint AS606 512GB) |
| Worker | wn-01 | .200 | TRIGKEY G4 (N100) | NVMe |
| Worker | wn-02 | .201 | NiPoGi AK2Plus (N100) | SATA |
| Worker | wn-03 | .202 | MINISFORUM UM790Pro (7940HS) | NVMe 1TB |

- VIP: `192.168.10.229` (Talos built-in, VLAN 10)
- インストーラー: `ghcr.io/tsuguya-hc/installer` (SecureBoot 署名済みカスタムビルド)
- CP の NIC は `enp3s0`（I226-V ×2 のうち LAN を挿す方）。`install.disk` は固定名でなく `diskSelector: busPath` で SATA AHCI 配下を指定
- CNI: Cilium（`cluster.network.cni.name: none`、kube-proxy 無効）

## Talos の版上げ

`cluster.yaml` の `talosVersion` は生成時の version contract で、installer image のタグでもある。
上げると生成物が新しい形式（1.14 なら v1alpha1 から分離されたドキュメント群）になるので、
patch の書き換えとセットで行う。ノードの適用は `make upgrade`（1 台ずつ stage → reboot）。
