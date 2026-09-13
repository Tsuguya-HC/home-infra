# Secrets のローテーション

前提: 秘密は「漏れたら回す」もので、回す手順は普段意識しない。だから 1 コマンド列に落として
ある。バンドル（`talosctl gen secrets` 形式、1Password の Document `talos-secrets-bundle`）
に入っている 14 の値は、回し方で 3 つに分かれる。

| 値 | 回し方 | 影響 |
|---|---|---|
| `certs.k8s`（Kubernetes API CA） | `scripts/rotate-ca.sh kubernetes --apply` | 段階ローテーション。全 kubeconfig が無効になり再発行。**起動時に CA を読んだクライアントは黙って死ぬ**ので直後に `restart-workloads.sh` |
| `certs.os`（Talos API CA） | `scripts/rotate-ca.sh talos --apply` | 段階ローテーション。全 talosconfig が無効。ローカルと 1Password（Document `talos-admin-talosconfig`）と ESO を配り直す（スクリプトがやる） |
| `trustdinfo.token` / `secrets.bootstraptoken` | `scripts/rotate-bundle.sh <key>` | 稼働ノードは気づかない。新規ノードの join に効く |
| `cluster.id` / `cluster.secret`（discovery） | 同上 | 30 分ほど `talosctl get members` が欠ける |
| `certs.k8saggregator` | 同上 | apiserver 再起動、集約 API（metrics-server）が揃うまで数分ブレる（1.13 は即時切替） |
| `certs.k8sserviceaccount` | 同上 | **全 SA トークン無効**。直後に `restart-workloads.sh`（1.13 は即時切替、1.14 は `accepted.publicKeys` で段階化できる） |
| `secrets.secretboxencryptionsecret` | 1.14 の `KubeEtcdEncryptionConfig` で 7 段階 | 1.13 は鍵 1 本しか書けず無損失で回せない。スクリプトは拒否する |
| `certs.etcd`（etcd CA） | 手動、graceful な経路なし（上流 #8808） | CP 3 台の `cluster.etcd.ca` を続けて差し替え |

## 全部回すとき（今日のような漏洩後）

```bash
cd home-infra
scripts/rotate-ca.sh kubernetes            # dry-run で手順を見る
scripts/rotate-ca.sh kubernetes --apply    # 1 分。終わると kubeconfig 再発行、バンドル同期
scripts/rotate-ca.sh talos --apply         # talosconfig を配り直し、バンドル同期
scripts/rotate-bundle.sh trustdinfo.token secrets.bootstraptoken cluster.id cluster.secret \
  certs.k8saggregator certs.k8sserviceaccount
scripts/restart-workloads.sh               # CA と SA 鍵が変わったので全部巻き直す
make diff                                  # 全台 No changes
scripts/secrets-sync.sh                    # 稼働 CP から再構成したバンドル = 1Password
```

secretbox と etcd CA は残る。secretbox は 1.14 に上げてから。

## 仕組み

- **稼働側が正**: `secrets-sync.sh` は最初の CP の適用済み設定から `talosctl gen secrets --from-controlplane-config` でバンドルを再構成し、1Password と比較する（値は出さずキーごとの same/DIFF）。`rotate-ca` のようにノードを直接書き換える操作の後は `--push` で 1Password を追従させる。これで `make genconfig` の生成物とノードが一致し続ける
- **バンドルだけが持つ値**は逆向き: `rotate-bundle.sh` が 1Password を書き換え、`make genconfig` → `scripts/apply.sh` でノードに流す（再起動なし）
- 出力は 40 文字を超えるトークンを含む行を落として表示する。`rotate-ca` は新しい CA の鍵を stdout に出すので、生ログは一時ファイルにしか置かない
- PXE 配信の machine config は git の変更で同期されるため、ローテーション後は手動で
  `argo -n argo submit --from workflowtemplate/pxe-sync -p mode=sync-configs` を流す（ESO の `talos-secrets` は 1 時間以内に追従する。急ぐなら `kubectl -n argo annotate externalsecret talos-secrets force-sync=$(date +%s)`）

## 検証は結果で見る

- Pod が Running かではなく、ArgoCD の `status.reconciledAt` が動いているか、controller のログに x509 が無いか（`restart-workloads.sh` が出す）
- `make diff` が全台 No changes、`secrets-sync.sh` が in sync
