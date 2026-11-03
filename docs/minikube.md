# Deploy the example on Minikube with Argo CD

The checks use `kubectl` against one Minikube profile, `kustomize-example`. They do not use the current kubectl context, and they refuse every other context name.

You need Docker, Minikube, and kubectl. Argo CD v3.5.6 is the cluster install because that release ships Kustomize 5.8.1. The repo server must print `v5.8.1`. A 5.6 binary will not render `sourceValue` or `kind: Deployment|StatefulSet|Job`.

One node cannot carry both compute profiles, and it cannot be two environments at once. The profile starts with two nodes. `scripts/verify.sh` labels them `cpu` and `gpu`, then moves `my.cluster/environment` through `dev`, `qa`, and `prod`.

## Steps

From the repository root:

```bash
minikube start -p kustomize-example --driver=docker --nodes=2 --cpus=2 --memory=3072 --kubernetes-version=v1.37.2
kubectl --context kustomize-example wait --for=condition=Ready nodes --all --timeout=180s
kubectl --context kustomize-example taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true

kubectl --context kustomize-example get nodes --sort-by=.metadata.name
```

Label the first node `cpu` and the second `gpu`. Both start as `dev`. `scripts/verify.sh` changes the environment label later.

```bash
kubectl --context kustomize-example label node <cpu-node> my.cluster/environment=dev my.cluster/compute=cpu --overwrite
kubectl --context kustomize-example label node <gpu-node> my.cluster/environment=dev my.cluster/compute=gpu --overwrite
```

Install Argo CD v3.5.6 and apply the three Applications:

```bash
kubectl --context kustomize-example create namespace argocd
kubectl --context kustomize-example apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
kubectl --context kustomize-example rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl --context kustomize-example rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl --context kustomize-example exec -n argocd deploy/argocd-repo-server -- kustomize version
kubectl --context kustomize-example apply --server-side --force-conflicts -f argocd/job-health.yaml
kubectl --context kustomize-example apply -f argocd/applications.yaml
```

`kustomize version` must print `v5.8.1`. The Applications track `main` of this repository. The overlays pin `kustomize-library` to a commit.

`argocd/job-health.yaml` tells Argo CD that a running Job is healthy. The example Job uses `registry.k8s.io/pause:3.10`, which does not exit. Without that check, sync waits on wave 76 and never applies the CronJob at wave 78.

`./scripts/deploy.sh` is the same sequence.

## Tests

```bash
./scripts/verify.sh
```

The script is `kubectl` only. For each of `dev`, `qa`, and `prod` it checks:

| Check | Pass |
| --- | --- |
| Application `example-dev`, `example-qa`, `example-main` | `.status.sync.status` is `Synced` |
| Repo server | `kustomize version` is `v5.8.1` |
| `example-deployment` | environment and `gpu` affinity, wave `70`, running on the gpu node |
| `example-statefulset-notin-afm` | `cpu` affinity, `scale.spectrum.ibm.com/role` `NotIn` `afm`, wave `70`, cpu node |
| `example-statefulset-afm-allowed` | `cpu` affinity, no AFM expression, wave `70`, cpu node |
| `example-job` | `cpu` affinity, wave `76`, pod Ready on the cpu node |
| `example-cron-job` | `cpu` affinity, wave `78`, schedule `0 * * * *` |
| Labels | `app.kubernetes.io/managed-by=argocd` and `my.cluster/environment` on the resource and the Pod template |
| Compute label | Present on the workload, absent from the Pod template |
| Sync wave | Absent from the Pod template |
| Namespace | Sync wave `-10` |
| `scheduling-settings` | Not in the namespace |
| Image | `registry.k8s.io/pause:3.10` |

`PASS verify` is the last line. The pause Job does not exit, so the Application health stays `Progressing`. The test uses the sync status and the Ready pods, not that health field.

The `main` overlay is the `prod` namespace. Its node environment is `prod`.
