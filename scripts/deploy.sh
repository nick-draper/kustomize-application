#!/bin/bash
# Start the single Minikube profile named minikube, install Argo CD v3.5.6,
# and sync the three example Applications.
#
# Usage (from the repository root):
#   ./scripts/deploy.sh
#
# The script only talks to the profile named minikube.
# It restores the kubectl context it found on entry.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "${root}"

profile=minikube
ctx=minikube
argocd_manifest=https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "Minikube profile ${profile}"
prev=$(kubectl config current-context 2>/dev/null || true)
minikube start -p "${profile}" --driver=docker --nodes=2 --cpus=2 --memory=3072 --kubernetes-version=v1.37.2
if [ -n "${prev}" ]; then
  kubectl config use-context "${prev}" >/dev/null
fi

echo "Nodes"
kubectl --context "${ctx}" wait --for=condition=Ready nodes --all --timeout=180s
# Minikube may taint the control plane. Both nodes must accept the example pods.
kubectl --context "${ctx}" taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
kubectl --context "${ctx}" taint nodes --all node-role.kubernetes.io/master:NoSchedule- >/dev/null 2>&1 || true

echo "Label nodes for dev (verify.sh moves the labels through qa and prod)"
i=0
while IFS= read -r name; do
  [ -n "${name}" ] || continue
  i=$((i + 1))
  if [ "${i}" -eq 1 ]; then
    compute=cpu
  else
    compute=gpu
  fi
  kubectl --context "${ctx}" label node "${name}" \
    my.cluster/environment=dev \
    my.cluster/compute="${compute}" \
    --overwrite >/dev/null
done < <(kubectl --context "${ctx}" get nodes --sort-by=.metadata.name -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ "${i}" -ge 2 ] || fail "profile ${profile} has ${i} node; cpu and gpu need two"

echo "Argo CD v3.5.6"
kubectl --context "${ctx}" get namespace argocd >/dev/null 2>&1 || kubectl --context "${ctx}" create namespace argocd
# Server-side apply avoids the applicationsets CRD last-applied annotation limit.
kubectl --context "${ctx}" apply -n argocd --server-side --force-conflicts -f "${argocd_manifest}"
kubectl --context "${ctx}" rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl --context "${ctx}" rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl --context "${ctx}" rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl --context "${ctx}" wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
# Merge one key. A server-side apply of this file alone replaces argocd-cm.
kubectl --context "${ctx}" patch configmap argocd-cm -n argocd --type merge --patch-file argocd/job-health.yaml

ver=$(kubectl --context "${ctx}" exec -n argocd deploy/argocd-repo-server -- kustomize version)
[ "${ver}" = "v5.8.1" ] || fail "Argo CD repo server kustomize is '${ver}', expected v5.8.1"

echo "Applications"
kubectl --context "${ctx}" apply -f argocd/applications.yaml
for app in example-dev example-qa example-main; do
  echo "Wait for ${app} to sync"
  synced=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    synced=$(kubectl --context "${ctx}" get application "${app}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    [ "${synced}" = "Synced" ] && break
    sleep 10
  done
  [ "${synced}" = "Synced" ] || fail "${app} sync status is '${synced:-<empty>}'"
  echo "PASS sync ${app}"
done

echo "Deployed. Next: ./scripts/verify.sh"
echo "kubectl context left at '${prev:-<none>}'"
