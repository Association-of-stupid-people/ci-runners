# ci-runners

Self-hosted GitHub Actions runners for the `Association-of-stupid-people` org: a single-node
[k3s](https://k3s.io) cluster running [Actions Runner Controller](https://github.com/actions/actions-runner-controller)
(ARC) runner scale sets. Runners are registered at the **org** level, so any repo in the org that is
allowed by the runner group can use them.

| Scale set | Max jobs | Limits (per pod) | Docker data | Use for |
|---|---|---|---|---|
| `bibg-heavy` | 1 | dind 10 CPU / 8 GiB | kept across jobs (`/var/lib/bibg-ci/heavy-docker`) | BIBGSystem only (Rust build, backend image) |
| `bibg-light` | 2 | dind 3 CPU / 2.5 GiB, runner 3 CPU / 3 GiB | fresh every job | any repo |

Each job pod has its own Docker daemon (dind), so `container:` jobs, `services:` and `docker build` work.

**Other repos use `bibg-light`.** `bibg-heavy` keeps images, build cache and volumes between jobs and
builds a published image, so a job from another repo could read or poison that state. On a plan with
custom runner groups, move it to a group limited to BIBGSystem (`runnerGroup:` in its yaml).

## Install on a new host

Requirements: Ubuntu x86_64, ~16 GiB RAM, sudo, outbound HTTPS. Nothing else needs to be preinstalled.

```bash
git clone https://github.com/Association-of-stupid-people/ci-runners.git
cd ci-runners
sudo bash bootstrap.sh   # k3s + helm + ARC controller (skips what is already installed)
sudo bash install.sh     # scale sets; asks for the GitHub PAT the first time
```

The PAT is a classic token with `admin:org`, from an org owner. It is stored only in the k8s
secret `arc-github` (namespace `arc-runners`). Never commit it. Without a terminal (e.g. `ssh host cmd`),
pass it as `GH_PAT=... sudo -E bash install.sh`.

## Use in a workflow

```yaml
jobs:
  build:
    runs-on: bibg-light
```

- **Private repos only by default.** The org runner group `Default` does not allow public repos.
  Leave it that way: a fork PR would otherwise run privileged containers on this machine.
  Check access under *Org settings → Actions → Runner groups*.
- **The runner image is bare** (`ghcr.io/actions/actions-runner`): no Node, Python, Rust, etc.
  Use `actions/setup-*` or run the job in a `container:`.
- **Capacity is shared by the whole org.** Jobs beyond `maxRunners` wait in the queue.

## Operations

All commands run on the runner host.

```bash
git pull && sudo bash install.sh             # apply changes from this repo
kubectl -n arc-systems get pods              # controller + one listener per scale set
kubectl -n arc-runners get pods              # running job pods
kubectl -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener --tail=50
kubectl -n arc-systems logs deploy/arc-gha-rs-controller --tail=50
```

**Rotate the PAT** (CI stops picking up jobs when it expires):

```bash
sudo kubectl -n arc-runners delete secret arc-github
sudo bash install.sh                         # prompts for the new token
kubectl -n arc-systems delete pod -l app.kubernetes.io/component=runner-scale-set-listener
```

**Add a scale set:** copy a file in `scale-sets/`, change `runnerScaleSetName` (keep the file name
equal to it) and the limits, run `install.sh`. Every `*.yaml` in that folder becomes a live scale set.
Keep the sum of memory limits within the host.

**Remove a scale set:** delete its file, then `sudo helm uninstall <name> -n arc-runners`.

**Upgrade ARC** (helm never upgrades CRDs, so the controller is reinstalled): wait until no job is
running, then

```bash
for s in scale-sets/*.yaml; do sudo helm uninstall "$(basename "$s" .yaml)" -n arc-runners --wait; done
sudo helm uninstall arc -n arc-systems --wait
sudo kubectl get crd -o name | grep actions.github.com | xargs sudo kubectl delete
# set ARC_VERSION in versions.env, then
sudo bash bootstrap.sh && sudo bash install.sh
```

**Upgrade k3s:** set `K3S_VERSION` in `versions.env`, then
`curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION=<version> sh -` (flags come from
`/etc/rancher/k3s/config.yaml`, written by `bootstrap.sh`). `bootstrap.sh` itself never upgrades an
installed k3s or helm.

**Uninstall everything:** `sudo /usr/local/bin/k3s-uninstall.sh && sudo rm -rf /var/lib/bibg-ci`.

## Troubleshooting

- **Job stays "Waiting for a runner"**: the repo is not allowed by the runner group (or is public),
  the `runs-on` label is misspelled, or the PAT expired (listener logs show 401).
- **`Connection reset by peer` inside `container:` jobs**: Docker networks must use the pod MTU
  (flannel: 1450). The scale sets pass `--mtu=1450` to dockerd; keep it when adding new ones.
- **Heavy job killed (OOMKilled)**: lower build parallelism (e.g. `CARGO_BUILD_JOBS`) or raise the
  dind memory limit in `scale-sets/bibg-heavy.yaml`.
