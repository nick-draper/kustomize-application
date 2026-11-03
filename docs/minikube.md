# Deploy the example on Minikube with Argo CD

Use the one local Minikube profile, named `minikube`. The commands pass `--context minikube`, so they do not follow whatever context kubectl is currently using. `scripts/verify.sh` refuses any other context name.

These are the steps and the tests. Running them is left to you.

You need Docker, Minikube, and kubectl. Argo CD v3.5.6 is the cluster install because that release ships Kustomize 5.8.1. The repo server must print `v5.8.1`. A 5.6 binary will not render `sourceValue` or `kind: Deployment|StatefulSet|Job`.

One node cannot carry both compute profiles, and it cannot be two environments at once. The profile starts with two nodes. `scripts/verify.sh` labels them `cpu` and `gpu`, then moves `my.cluster/environment` through `dev`, `qa`, and `prod`.

## Steps

From the repository root:

```bash
minikube start -p minikube --driver=docker --nodes=2 --cpus=2 --memory=3072 --kubernetes-version=v1.37.2
kubectl --context minikube wait --for=condition=Ready nodes --all --timeout=180s
kubectl --context minikube taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true

kubectl --context minikube get nodes --sort-by=.metadata.name
```

Label the first node `cpu` and the second `gpu`. Both start as `dev`. `scripts/verify.sh` changes the environment label later.

```bash
kubectl --context minikube label node <cpu-node> my.cluster/environment=dev my.cluster/compute=cpu --overwrite
kubectl --context minikube label node <gpu-node> my.cluster/environment=dev my.cluster/compute=gpu --overwrite
```

Install Argo CD v3.5.6 and apply the three Applications:

```bash
kubectl --context minikube create namespace argocd
kubectl --context minikube apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
kubectl --context minikube rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl --context minikube rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl --context minikube exec -n argocd deploy/argocd-repo-server -- kustomize version
kubectl --context minikube patch configmap argocd-cm -n argocd --type merge --patch-file argocd/job-health.yaml
kubectl --context minikube apply -f argocd/applications.yaml
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

`PASS verify` is the last line. The pause Job does not exit, so the Application health stays `Progressing` until `argocd/job-health.yaml` is merged into `argocd-cm`. The test uses the sync status and the Ready pods, not that health field.

Patch that file. Do not `kubectl apply` it on its own. A partial apply replaces `argocd-cm` and Argo CD then reports the ConfigMap missing.

The same reads for `qa` and for `prod` (the `main` overlay). Shown here for `dev`:

```bash
kubectl --context minikube exec -n argocd deploy/argocd-repo-server -- kustomize version
kubectl --context minikube get application example-dev -n argocd -o jsonpath='{.status.sync.status}'

kubectl --context minikube get deploy example-deployment -n dev \
  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[?(@.key=="my.cluster/compute")].values[0]}'
kubectl --context minikube get deploy example-deployment -n dev \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}'

kubectl --context minikube get sts example-statefulset-notin-afm -n dev \
  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[?(@.key=="scale.spectrum.ibm.com/role")].operator}'
kubectl --context minikube get sts example-statefulset-afm-allowed -n dev \
  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[?(@.key=="scale.spectrum.ibm.com/role")].operator}'

kubectl --context minikube get job example-job -n dev \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}'
kubectl --context minikube get cronjob example-cron-job -n dev \
  -o jsonpath='{.spec.schedule}'

kubectl --context minikube get namespace dev \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}'
kubectl --context minikube get configmap scheduling-settings -n dev
```

Pass values are `v5.8.1`, `Synced`, `gpu`, `70`, `NotIn`, an empty AFM operator on the allowed StatefulSet, `76`, `0 * * * *`, and `-10`. The ConfigMap get must exit non-zero. `./scripts/verify.sh` runs these checks, then repeats them after relabeling the nodes for `qa` and `prod`.
