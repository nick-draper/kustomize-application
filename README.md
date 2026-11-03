[![Kustomize](https://img.shields.io/badge/Kustomize-5.8.1-326ce5?logo=kubernetes&logoColor=white)](https://github.com/kubernetes-sigs/kustomize/releases/tag/kustomize%2Fv5.8.1)
[![Argo CD](https://img.shields.io/badge/Argo%20CD-3.5.6-ef7b4d?logo=argo&logoColor=white)](https://github.com/argoproj/argo-cd/releases/tag/v3.5.6)
[![Scope](https://img.shields.io/badge/scope-minikube%20example-0e6027)](docs/minikube.md)
[![Last commit](https://img.shields.io/github/last-commit/nick-draper/kustomize-application)](https://github.com/nick-draper/kustomize-application/commits/main)

# Example application

Three overlays, `dev`, `qa`, and `main`, on the components in [kustomize-library](https://github.com/nick-draper/kustomize-library). `main` is production: the namespace and the node environment are `prod`.

Argo CD v3.5.6 renders the overlays. That release ships Kustomize 5.8.1, which is the version `sourceValue` and `kind: Deployment|StatefulSet|Job` require.

## Who this is for

Someone who wants to see the library schedule a Deployment, two StatefulSets, a Job, and a CronJob on Minikube, with the compute profile taken from the workload label.

## Deploy and test

The steps are in [docs/minikube.md](docs/minikube.md). From this repository:

```bash
./scripts/deploy.sh
./scripts/verify.sh
```

`deploy.sh` starts the Minikube profile `kustomize-example` (two nodes), installs Argo CD v3.5.6, and applies [argocd/applications.yaml](argocd/applications.yaml). It restores the kubectl context it found on entry. It does not talk to any other context.

`verify.sh` is `kubectl` only. It labels the nodes for `dev`, then `qa`, then `prod`, and checks affinity, labels, sync waves, node placement, and that the build-only ConfigMap was not applied. `PASS verify` is the success line.

## Paths

| Path | Role |
|------|------|
| [base/](base/) | Example workloads. Compute labels live here |
| [overlays/dev](overlays/dev/) | Environment `dev`, namespace `dev` |
| [overlays/qa](overlays/qa/) | Environment `qa`, namespace `qa` |
| [overlays/main](overlays/main/) | Environment `prod`, namespace `prod` |
| [argocd/applications.yaml](argocd/applications.yaml) | Argo CD Applications for the three overlays |
| [docs/minikube.md](docs/minikube.md) | The Minikube and Argo CD commands, and the pass/fail table |
| [scripts/deploy.sh](scripts/deploy.sh) | Those commands |
| [scripts/verify.sh](scripts/verify.sh) | The `kubectl` checks |

The overlays pin `kustomize-library` to one commit. Argo CD tracks `main` of this repository.

## Out of scope

- GPU device requests. The gpu node only needs the label `my.cluster/compute=gpu`
- A cluster other than the `kustomize-example` Minikube profile
- Kustomize versions other than 5.8.1

## Further reading

- [kustomize-library](https://github.com/nick-draper/kustomize-library)
- [Kustomize replacements](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/replacements/)
- [Argo CD sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
