# ci-runners

Self-hosted GitHub Actions runners: a single-node [k3s](https://k3s.io) cluster running
[Actions Runner Controller](https://github.com/actions/actions-runner-controller) (ARC) runner scale sets,
registered at the org (or repo) set in `config.env`. Any repo the org's runner group allows can use them.

| Scale set | Resources per job | Docker data | Use for |
|---|---|---|---|
| `ci-2c-2g`, `ci-4c-4g`, `ci-4c-8g`, `ci-8c-8g` | the cores / GiB in the name, reserved and capped | fresh every job (pod evicted if workspace > 10 GiB or Docker data > 30 GiB) | any repo: pick the size the job needs |
| `bibg-heavy` | reserves ~8.25 GiB, may use up to 9 GiB, max 1 | kept across jobs (`/var/lib/bibg-ci/heavy-docker`) | BIBGSystem only (Rust build, backend image) |
| `bibg-light` | reserves 1 GiB, may use up to 5.5 GiB, max 2 | fresh every job | BIBGSystem |

Each job pod has its own Docker daemon (dind), so `container:` jobs, `services:` and `docker build` work.

### How sizes share the machine

A `ci-<C>c-<G>g` pod gets exactly C cores and G GiB (shared by the runner and its Docker daemon), like a
hosted runner size. Kubernetes starts a job pod only where those cores and that memory are free, so the same
machine is used as needed: 8 cores / 8 GiB free runs 4 x `ci-2c-2g`, 2 x `ci-4c-4g`, 1 x `ci-8c-8g` or a mix
(1 x `ci-4c-4g` + 2 x `ci-2c-2g`). A job that does not fit waits in the queue (its pod stays Pending) and
starts when resources free up. `maxRunners` of each size is how many fit in the whole node.

Choose the sizes with `CI_SIZES` in `config.env` (`<cores>c<GiB>g`, e.g. `CI_SIZES="2c2g 4c8g"`), then run
`install.sh`. Sizes that do not fit the node are skipped with a message.

Limits of the packing:
- A waiting big job does not reserve resources: smaller jobs that fit keep starting, so a steady stream of
  small jobs can delay a big one. On a 16 GiB host `ci-8c-8g` cannot start while `bibg-heavy` runs.
- `ci-*` pods are Guaranteed: they never use more than they reserve, and when RAM runs out the kernel kills
  processes of the bursting `bibg-*` pods (which reserve less than they may use) first.
- A job over its memory is OOM-killed inside its own pod; the victim may be the runner or Docker rather
  than the build, so the job can fail as "runner lost" instead of exit code 137.

**Other repos use `ci-*`.** `bibg-heavy` keeps images, build cache and volumes between jobs and
builds a published image, so a job from another repo could read or poison that state. On a plan with
custom runner groups, move it to a group limited to BIBGSystem (`runnerGroup:` in its yaml).

## Install on a new host

Requirements: Ubuntu x86_64, ~16 GiB RAM, sudo, outbound HTTPS. Nothing else needs to be preinstalled.

```bash
git clone https://github.com/Association-of-stupid-people/ci-runners.git
cd ci-runners
# edit config.env first when the runners are for another org/repo
sudo bash setup.sh       # = bootstrap.sh (k3s + helm + ARC controller) + install.sh (scale sets)
```

`setup.sh` asks for the GitHub PAT the first time. Both steps can also be run on their own; re-running
is safe (installed parts are skipped, scale sets are upgraded in place).

The PAT is a classic token with `admin:org` from an org owner (for a repo URL: `repo` scope from a repo
admin). It is stored only in the k8s
secret `arc-github` (namespace `arc-runners`). Never commit it. Over ssh, give the prompt a terminal:
`ssh -t <host> 'cd ci-runners && sudo bash setup.sh'`. `GH_PAT=... sudo -E bash setup.sh` is for
automation only (the token lands in shell history).

`helm`/`kubectl` without sudo use the `~/.kube/config` that `bootstrap.sh` copies for the invoking user,
via `KUBECONFIG` in `~/.bashrc` (open a new shell or `source ~/.bashrc` after bootstrap);
`sudo helm` has no kubeconfig.

## Use in a workflow

```yaml
jobs:
  build:
    runs-on: ci-4c-8g
```

- **Private repos only by default.** The org runner group `Default` does not allow public repos.
  Leave it that way: a fork PR would otherwise run privileged containers on this machine.
  Check access under *Org settings → Actions → Runner groups*.
- **The runner image is bare** (`ghcr.io/actions/actions-runner`): no Node, Python, Rust, etc.
  Use `actions/setup-*` or run the job in a `container:`.
- **Capacity is shared by the whole org.** Jobs that do not fit in the free cores and memory wait in the queue.
- **Choose the smallest size that works.** A job killed by OOM (exit code 137 or "runner lost") needs the
  next size up.

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
For a new size of the fresh-pod kind, add it to `CI_SIZES` instead (see "How sizes share the machine").

**Remove a scale set:** delete its file (or its size from `CI_SIZES`), then
`helm uninstall <name> -n arc-runners`.

**Upgrade ARC** (helm never upgrades CRDs, so the controller is reinstalled): wait until no job is
running, then

```bash
(
  set -e   # stop at the first failure: CRDs must not be deleted while ARC is still installed
  rs=$(helm list -a -n arc-runners -q)
  for r in $rs; do helm uninstall "$r" -n arc-runners --wait; done
  helm uninstall arc -n arc-systems --wait --ignore-not-found
  kubectl get crd -o name | grep actions.github.com | xargs -r kubectl delete
)
```

Then set `ARC_VERSION` in `versions.env` and run `sudo bash bootstrap.sh && sudo bash install.sh`.

**Upgrade k3s:** set `K3S_VERSION` in `versions.env`, then
`curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION=<version> sh -` (flags come from
`/etc/rancher/k3s/config.yaml`, written by `bootstrap.sh`; on a host set up before that file existed,
run `sudo bash bootstrap.sh` once first or the installer drops the flags). `bootstrap.sh` itself never
upgrades an installed k3s or helm.

**Uninstall everything:** `sudo /usr/local/bin/k3s-uninstall.sh && sudo rm -rf /var/lib/bibg-ci`.

## Troubleshooting

- **Job stays "Waiting for a runner"**: the repo is not allowed by the runner group (or is public),
  the `runs-on` label is misspelled, or the PAT expired (listener logs show 401).
- **`Connection reset by peer` inside `container:` jobs**: Docker networks must use the pod MTU
  (flannel: 1450). The scale sets pass `--mtu=1450` to dockerd; keep it when adding new ones.
- **Heavy job killed (OOMKilled)**: lower build parallelism (e.g. `CARGO_BUILD_JOBS`) or raise the
  dind memory limit in `scale-sets/bibg-heavy.yaml`.
