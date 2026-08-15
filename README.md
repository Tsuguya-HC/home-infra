# home-infra

[talhelper](https://github.com/budimanjojo/talhelper) を使った Talos Linux ノード設定管理。

## 構成

| ファイル | 説明 |
|---------|------|
| `talconfig.yaml` | 全ノード定義・パッチ（唯一の編集対象） |
| `talsecret.sops.yaml` | SOPS 暗号化された Talos secrets |
| `Makefile` | 設定生成・適用コマンド |
| `clusterconfig/` | talhelper 生成物（.gitignore 済み） |

## ワークフロー

```bash
# 1. talconfig.yaml を編集

# 2. 設定ファイルを生成
make genconfig

# 3. 差分確認（dry-run）
make diff

# 4. ノードに適用
make apply
```

## クラスタ構成

| ロール | ホスト名 | IP | HW | Disk |
|--------|----------|-----|-----|------|
| CP | cp-13/cp-11/cp-12 | .230/.231/.232 | AOOSTAR N1 Pro (N150) | SATA M.2 (ASint AS606 512GB) |
| Worker | wn-01 | .200 | TRIGKEY G4 (N100) | NVMe |
| Worker | wn-02 | .201 | NiPoGi AK2Plus (N100) | SATA |
| Worker | wn-03 | .202 | MINISFORUM UM790Pro (7940HS) | NVMe 1TB |

- VIP: `192.168.10.229` (Talos built-in, VLAN 10)
- インストーラー: `ghcr.io/tsuguya/installer` (SecureBoot 署名済みカスタムビルド)
- CP の NIC は `enp3s0`（I226-V ×2 のうち LAN を挿す方）。`installDisk` は固定名でなく `installDiskSelector: busPath` で SATA AHCI 配下を指定
- CNI: Cilium（`cniConfig.name: none`、kube-proxy 無効）

## Secrets

`talsecret.sops.yaml` は SOPS で暗号化。平文 `talsecret.yaml` は `.gitignore` 済み。

```bash
# secrets の復号（作業時のみ）
sops -d talsecret.sops.yaml > talsecret.yaml
```

## talosconfig

```bash
# VIPではなく直接CPのIPを使う（gRPCストリーム問題回避）
# ~/.talos/config: endpoints = 192.168.0.230, .231, .232
talosctl -n <node-ip> <command>
```
