#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-keda-demo}"
APP_NAME="${APP_NAME:-messages-api}"
APP_IMAGE="${APP_IMAGE:-}"
APP_PORT="${APP_PORT:-8080}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
MAX_REPLICAS="${MAX_REPLICAS:-5}"
CPU_TARGET="${CPU_TARGET:-60}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
KIND_CLUSTER="${KIND_CLUSTER:-}"
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
  [[ "$LOCAL_MODE" == "true" ]] && metrics_args+=(--set 'args={--kubelet-insecure-tls}')
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
      --set controller.image.repository=kind.local/kwok \
      --set controller.image.tag=latest \
      --set controller.resources.requests.cpu=1 \
      --set controller.resources.requests.memory=1Gi \
      --set settings.preferencePolicy=Ignore \
      --set settings.featureGates.staticCapacity=false \
      --set settings.featureGates.capacityBuffer=false \
      --wait --timeout 5m
  )
  rm -rf -- "$KARPENTER_SOURCE_DIR"
  KARPENTER_SOURCE_DIR=""
}

create_application_namespace() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

deploy_application() {
  APP_IMAGE="$APP_IMAGE" \
  NAMESPACE="$NAMESPACE" \
  APP_NAME="$APP_NAME" \
  APP_PORT="$APP_PORT" \
  MIN_REPLICAS="$MIN_REPLICAS" \
  MAX_REPLICAS="$MAX_REPLICAS" \
  CPU_TARGET="$CPU_TARGET" \
  envsubst <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: ${MIN_REPLICAS}
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
        - name: app
          image: ${APP_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: ${APP_PORT}
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${APP_NAME}
  ports:
    - name: http
      port: ${APP_PORT}
      targetPort: ${APP_PORT}
  type: ClusterIP
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${APP_NAME}-scaler
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    name: ${APP_NAME}
  pollingInterval: 5
  cooldownPeriod: 30
  minReplicaCount: ${MIN_REPLICAS}
  maxReplicaCount: ${MAX_REPLICAS}
  triggers:
    - type: cpu
      metricType: Utilization
      metadata:
        value: "${CPU_TARGET}"
YAML
}

wait_for_deployment() {
  echo "Aguardando o Deployment..."
  kubectl rollout status "deployment/$APP_NAME" -n "$NAMESPACE" --timeout=180s
}

main() {
  parse_arguments "$@"
  validate_config
  check_commands
  detect_cluster
  build_local_image
  install_cluster_dependencies
  create_application_namespace
  deploy_application
  wait_for_deployment
}

main "$@"
