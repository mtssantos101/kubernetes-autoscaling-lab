#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-autoscaling-lab}"
APP_NAME="${APP_NAME:-messages-api}"
APP_IMAGE="${APP_IMAGE:-}"
APP_PORT="${APP_PORT:-8080}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
MAX_REPLICAS="${MAX_REPLICAS:-10}"
CPU_TARGET="${CPU_TARGET:-60}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
KIND_CLUSTER="${KIND_CLUSTER:-}"
KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-}"
LOCAL_MODE="false"

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --local)
        LOCAL_MODE=true
        if [[ -z "$APP_IMAGE" ]]; then
          APP_IMAGE="${APP_NAME}:local"
        fi
        ;;
      -h|--help)
        echo "Uso: $0 [--local]"
        echo "  --local  Constrói a aplicação e configura Kind com KWOK e Karpenter KWOK."
        exit 0
        ;;
      *)
        echo "ERRO: argumento desconhecido: $1" >&2
        echo "Uso: $0 [--local]" >&2
        exit 2
        ;;
    esac
    shift
  done
}

check_commands() {
  local cmd
  for cmd in kubectl helm envsubst; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "ERRO: instale o comando $cmd primeiro." >&2
      exit 1
    }
  done

  if [[ "$LOCAL_MODE" == "true" ]]; then
    command -v docker >/dev/null 2>&1 || {
      echo "ERRO: --local requer Docker instalado." >&2
      exit 1
    }
    for cmd in kind git make go ko; do
      [[ -x "$(command -v "$cmd" 2>/dev/null)" ]] || {
        echo "ERRO: --local requer o comando $cmd instalado." >&2
        exit 1
      }
    done
  fi
}

validate_config() {
  if [[ -z "$APP_IMAGE" ]]; then
    echo "ERRO: defina APP_IMAGE (por exemplo, APP_IMAGE=messages-api:1.0)." >&2
    exit 1
  fi
}

detect_cluster() {
  kubectl cluster-info >/dev/null
  CONTEXT="$(kubectl config current-context)"
  echo "Cluster: $CONTEXT"
  echo "Namespace: $NAMESPACE"

  if [[ "$LOCAL_MODE" == "true" && "$CONTEXT" != kind-* ]]; then
    echo "ERRO: --local requer um cluster Kind ativo (contexto kind-<nome>)." >&2
    exit 1
  fi

  if [[ "$CONTEXT" == kind-* ]]; then
    KIND_CLUSTER="${KIND_CLUSTER:-${CONTEXT#kind-}}"
    echo "Modo local: Kind + KWOK + Karpenter KWOK"
  else
    echo "Imagem: ${APP_IMAGE:-não alterada}"
    echo "Atenção: este script não configura Karpenter nem permissões cloud."
  fi
}

build_local_image() {
  [[ "$LOCAL_MODE" == "true" ]] || return 0

  echo "Construindo imagem local: $APP_IMAGE"
  docker build -f "$DOCKERFILE" -t "$APP_IMAGE" "$BUILD_CONTEXT"

  kind load docker-image "$APP_IMAGE" --name "$KIND_CLUSTER"
}

install_cluster_dependencies() {
  if [[ "$LOCAL_MODE" == "true" ]]; then
    install_kwok_karpenter
  fi

  helm repo add kedacore https://kedacore.github.io/charts
  helm repo update
  helm upgrade --install keda kedacore/keda \
    --namespace keda --create-namespace --wait --timeout 5m

  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
  helm repo update
  local metrics_args=()
  [[ "$LOCAL_MODE" == "true" ]] && metrics_args+=(--values "$SCRIPT_DIR/config/helm/metrics-server-local.yaml")
  helm upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system --wait --timeout 5m "${metrics_args[@]}"
}

install_kwok_karpenter() {
  KARPENTER_SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/karpenter-kwok.XXXXXX")"
  trap 'if [[ -n "${KARPENTER_SOURCE_DIR:-}" ]]; then rm -rf -- "$KARPENTER_SOURCE_DIR"; fi' EXIT

  echo "Obtendo o provider KWOK oficial do Karpenter..."
  git clone --depth 1 https://github.com/kubernetes-sigs/karpenter.git "$KARPENTER_SOURCE_DIR/karpenter"
  (
    cd "$KARPENTER_SOURCE_DIR/karpenter"
    KWOK_REPO=kind.local KIND_CLUSTER_NAME="$KIND_CLUSTER" make install-kwok
    KO_DOCKER_REPO=kind.local/kwok KIND_CLUSTER_NAME="$KIND_CLUSTER" ko build --bare sigs.k8s.io/karpenter/kwok
    kubectl apply -f kwok/charts/crds
    helm upgrade --install karpenter ./kwok/charts \
      --namespace kube-system --skip-crds \
      --values "$SCRIPT_DIR/config/helm/karpenter-kwok.yaml" \
      --wait --timeout 5m
  )
  rm -rf -- "$KARPENTER_SOURCE_DIR"
  KARPENTER_SOURCE_DIR=""

  adopt_helm_resources kube-system karpenter-kwok-config \
    kwoknodeclasses.karpenter.kwok.sh/default nodepools.karpenter.sh/default
  helm upgrade --install karpenter-kwok-config "$SCRIPT_DIR/charts/karpenter-kwok-config" \
    --namespace kube-system --wait --timeout 5m
}

create_application_namespace() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

adopt_helm_resources() {
  local namespace="$1" release="$2" resource owner
  shift 2

  helm status "$release" --namespace "$namespace" >/dev/null 2>&1 && return 0

  for resource in "$@"; do
    kubectl get "$resource" --namespace "$namespace" >/dev/null 2>&1 || continue
    owner="$(kubectl get "$resource" --namespace "$namespace" \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}')"
    if [[ -n "$owner" && "$owner" != "$release" ]]; then
      echo "ERRO: $resource já pertence ao release Helm '$owner' em $namespace." >&2
      return 1
    fi
    kubectl label "$resource" --namespace "$namespace" \
      app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    kubectl annotate "$resource" --namespace "$namespace" \
      "meta.helm.sh/release-name=$release" \
      "meta.helm.sh/release-namespace=$namespace" --overwrite >/dev/null
  done
}

install_local_kafka() {
  [[ "$LOCAL_MODE" == "true" ]] || return 0

  KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-kafka.${NAMESPACE}.svc.cluster.local:9092}"
  adopt_helm_resources "$NAMESPACE" kafka svc/kafka deployment/kafka
  helm upgrade --install kafka "$SCRIPT_DIR/charts/kafka" \
    --namespace "$NAMESPACE" --create-namespace --wait --timeout 180s

  echo "Aguardando o Kafka local..."
  kubectl rollout status deployment/kafka -n "$NAMESPACE" --timeout=180s
}

deploy_application() {
  adopt_helm_resources "$NAMESPACE" "$APP_NAME" \
    "deployment/$APP_NAME" "service/$APP_NAME" "scaledobject/$APP_NAME-scaler"
  helm upgrade --install "$APP_NAME" "$SCRIPT_DIR/charts/messages-api" \
    --namespace "$NAMESPACE" --create-namespace --wait --timeout 5m \
    --set-string image="$APP_IMAGE" \
    --set-string kafkaBootstrapServers="${KAFKA_BOOTSTRAP_SERVERS:-localhost:9092}" \
    --set containerPort="$APP_PORT" \
    --set autoscaling.minReplicas="$MIN_REPLICAS" \
    --set autoscaling.maxReplicas="$MAX_REPLICAS" \
    --set autoscaling.cpuTarget="$CPU_TARGET"
}

wait_for_deployment() {
  echo "Aguardando o Deployment..."
  kubectl rollout status "deployment/$APP_NAME" -n "$NAMESPACE" --timeout=180s
}

install_observability_tools() {
  echo "Instalando ferramentas de observabilidade (Prometheus, Loki, Alloy, Grafana)..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add grafana-community https://grafana-community.github.io/helm-charts
  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo update

  helm upgrade --install loki grafana-community/loki \
    --namespace monitoring --create-namespace --wait --timeout 10m \
    --values "$SCRIPT_DIR/config/helm/observability/loki.yaml"

  helm upgrade --install prometheus prometheus-community/prometheus \
    --namespace monitoring --create-namespace --wait --timeout 5m

  helm upgrade --install grafana grafana-community/grafana \
    --namespace monitoring --create-namespace --wait --timeout 5m \
    --values "$SCRIPT_DIR/config/helm/observability/grafana.yaml"

  helm upgrade --install alloy grafana/alloy \
    --namespace monitoring --create-namespace --wait --timeout 5m \
    --values <(envsubst '${NAMESPACE}' < "$SCRIPT_DIR/config/helm/observability/alloy.yaml")

  if ! helm status observability-resources --namespace monitoring >/dev/null 2>&1; then
    kubectl delete configmap kafka-worker-dashboard -n monitoring --ignore-not-found
  fi
  helm upgrade --install observability-resources "$SCRIPT_DIR/charts/observability" \
    --namespace monitoring --create-namespace --wait --timeout 5m \
    --set-string appName="$APP_NAME"
}

main() {
  parse_arguments "$@"
  validate_config
  check_commands
  detect_cluster
  build_local_image
  install_cluster_dependencies
  create_application_namespace
  install_local_kafka
  deploy_application
  wait_for_deployment
  install_observability_tools
}

main "$@"; exit
