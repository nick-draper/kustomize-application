#!/bin/bash
# Check the example Applications on the Minikube profile named minikube.
#
# Usage (from the repository root, after ./scripts/deploy.sh):
#   ./scripts/verify.sh
#
# Every assertion is a kubectl read. The script labels the two nodes for
# dev, then qa, then prod, and checks the namespace that matches that label.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "${root}"

ctx=minikube

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

need() {
  local got=$1 expected=$2 message=$3
  [ "${got}" = "${expected}" ] || fail "${message}: got '${got}', expected '${expected}'"
}

echo "Context ${ctx}"
kubectl --context "${ctx}" cluster-info >/dev/null 2>&1 || fail "context ${ctx} is not reachable. Run ./scripts/deploy.sh"

echo "Argo CD Kustomize"
ver=$(kubectl --context "${ctx}" exec -n argocd deploy/argocd-repo-server -- kustomize version)
need "${ver}" "v5.8.1" "repo server kustomize version"

for app in example-dev example-qa example-main; do
  status=$(kubectl --context "${ctx}" get application "${app}" -n argocd -o jsonpath='{.status.sync.status}')
  need "${status}" "Synced" "${app} sync status"
done

label_env() {
  local env=$1
  local i=0
  local name compute
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    i=$((i + 1))
    if [ "${i}" -eq 1 ]; then
      compute=cpu
    else
      compute=gpu
    fi
    kubectl --context "${ctx}" label node "${name}" \
      my.cluster/environment="${env}" \
      my.cluster/compute="${compute}" \
      --overwrite >/dev/null
  done < <(kubectl --context "${ctx}" get nodes --sort-by=.metadata.name -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  [ "${i}" -ge 2 ] || fail "need two nodes, found ${i}"
}

json_get() {
  local kind=$1 name=$2 ns=$3 path=$4
  kubectl --context "${ctx}" get "${kind}" "${name}" -n "${ns}" -o "jsonpath=${path}"
}

pod_spec='{.spec.template.spec'
cron_spec='{.spec.jobTemplate.spec.template.spec'
pod_meta='{.spec.template.metadata'
cron_meta='{.spec.jobTemplate.spec.template.metadata'

env_value() {
  local kind=$1 name=$2 ns=$3 prefix=$4
  json_get "${kind}" "${name}" "${ns}" "${prefix}.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[?(@.key==\"my.cluster/environment\")].values[0]}"
}

compute_value() {
  local kind=$1 name=$2 ns=$3 prefix=$4
  json_get "${kind}" "${name}" "${ns}" "${prefix}.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[?(@.key==\"my.cluster/compute\")].values[0]}"
}

afm_operator() {
  local kind=$1 name=$2 ns=$3 prefix=$4
  json_get "${kind}" "${name}" "${ns}" "${prefix}.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[?(@.key==\"scale.spectrum.ibm.com/role\")].operator}"
}

check_workload() {
  local kind=$1 name=$2 ns=$3 env=$4 compute=$5 wave=$6 afm=$7 spec_prefix=$8 meta_prefix=$9
  local selector=${10:-}
  need "$(env_value "${kind}" "${name}" "${ns}" "${spec_prefix}")" "${env}" "${ns}/${name} environment affinity"
  need "$(compute_value "${kind}" "${name}" "${ns}" "${spec_prefix}")" "${compute}" "${ns}/${name} compute affinity"
  local role
  role=$(afm_operator "${kind}" "${name}" "${ns}" "${spec_prefix}")
  if [ "${afm}" = "yes" ]; then
    need "${role}" "NotIn" "${ns}/${name} AFM operator"
  else
    [ -z "${role}" ] || fail "${ns}/${name} has AFM exclusion '${role}'"
  fi
  need "$(json_get "${kind}" "${name}" "${ns}" '{.metadata.labels.app\.kubernetes\.io/managed-by}')" "argocd" "${ns}/${name} managed-by"
  need "$(json_get "${kind}" "${name}" "${ns}" '{.metadata.labels.my\.cluster/environment}')" "${env}" "${ns}/${name} environment label"
  need "$(json_get "${kind}" "${name}" "${ns}" '{.metadata.labels.scheduling\.my\.cluster/compute}')" "${compute}" "${ns}/${name} compute label"
  need "$(json_get "${kind}" "${name}" "${ns}" '{.metadata.annotations.argocd\.argoproj\.io/sync-wave}')" "${wave}" "${ns}/${name} sync-wave"
  need "$(json_get "${kind}" "${name}" "${ns}" "${meta_prefix}.labels.app\\.kubernetes\\.io/managed-by}")" "argocd" "${ns}/${name} pod managed-by"
  need "$(json_get "${kind}" "${name}" "${ns}" "${meta_prefix}.labels.my\\.cluster/environment}")" "${env}" "${ns}/${name} pod environment label"
  local pod_compute pod_wave
  pod_compute=$(json_get "${kind}" "${name}" "${ns}" "${meta_prefix}.labels.scheduling\\.my\\.cluster/compute}" || true)
  [ -z "${pod_compute}" ] || fail "${ns}/${name} copied the compute label onto the pod"
  pod_wave=$(json_get "${kind}" "${name}" "${ns}" "${meta_prefix}.annotations.argocd\\.argoproj\\.io/sync-wave}" || true)
  [ -z "${pod_wave}" ] || fail "${ns}/${name} copied the sync-wave onto the pod"
  need "$(json_get "${kind}" "${name}" "${ns}" "${spec_prefix}.containers[0].image}")" "registry.k8s.io/pause:3.10" "${ns}/${name} image"
  if [ -n "${selector}" ]; then
    need "$(json_get "${kind}" "${name}" "${ns}" '{.spec.selector.matchLabels.app}')" "${selector}" "${ns}/${name} selector"
  fi
}

node_of() {
  local ns=$1 prefix=$2
  kubectl --context "${ctx}" get pods -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' \
    | awk -v p="${prefix}" 'index($1, p)==1 { print $2; found=1; exit } END { if (!found) exit 1 }'
}

check_namespace() {
  local ns=$1 env=$2
  echo "Schedule ${ns}"
  label_env "${env}"
  local cpu_node gpu_node
  cpu_node=$(kubectl --context "${ctx}" get nodes -l "my.cluster/environment=${env},my.cluster/compute=cpu" -o jsonpath='{.items[0].metadata.name}')
  gpu_node=$(kubectl --context "${ctx}" get nodes -l "my.cluster/environment=${env},my.cluster/compute=gpu" -o jsonpath='{.items[0].metadata.name}')
  [ -n "${cpu_node}" ] && [ -n "${gpu_node}" ] && [ "${cpu_node}" != "${gpu_node}" ] || fail "cpu and gpu nodes were not labeled for ${env}"

  kubectl --context "${ctx}" rollout status deployment/example-deployment -n "${ns}" --timeout=180s
  kubectl --context "${ctx}" rollout status statefulset/example-statefulset-notin-afm -n "${ns}" --timeout=180s
  kubectl --context "${ctx}" rollout status statefulset/example-statefulset-afm-allowed -n "${ns}" --timeout=180s
  kubectl --context "${ctx}" wait --for=condition=Ready pod -l job-name=example-job -n "${ns}" --timeout=180s

  if kubectl --context "${ctx}" get configmap scheduling-settings -n "${ns}" >/dev/null 2>&1; then
    fail "scheduling-settings ConfigMap was applied in ${ns}"
  fi
  need "$(kubectl --context "${ctx}" get namespace "${ns}" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}')" "-10" "${ns} namespace sync-wave"

  check_workload deploy example-deployment "${ns}" "${env}" gpu 70 no "${pod_spec}" "${pod_meta}" example
  check_workload sts example-statefulset-notin-afm "${ns}" "${env}" cpu 70 yes "${pod_spec}" "${pod_meta}" example
  check_workload sts example-statefulset-afm-allowed "${ns}" "${env}" cpu 70 no "${pod_spec}" "${pod_meta}" example-afm-allowed
  check_workload job example-job "${ns}" "${env}" cpu 76 no "${pod_spec}" "${pod_meta}" ""
  check_workload cronjob example-cron-job "${ns}" "${env}" cpu 78 no "${cron_spec}" "${cron_meta}" ""
  need "$(json_get cronjob example-cron-job "${ns}" '{.spec.schedule}')" "0 * * * *" "${ns} cron schedule"

  need "$(node_of "${ns}" "example-deployment-")" "${gpu_node}" "${ns} deployment node"
  need "$(node_of "${ns}" "example-statefulset-notin-afm-")" "${cpu_node}" "${ns} notin-afm node"
  need "$(node_of "${ns}" "example-statefulset-afm-allowed-")" "${cpu_node}" "${ns} afm-allowed node"
  need "$(node_of "${ns}" "example-job-")" "${cpu_node}" "${ns} job node"
  echo "PASS ${ns}"
}

check_namespace dev dev
check_namespace qa qa
check_namespace prod prod
echo "PASS verify"
