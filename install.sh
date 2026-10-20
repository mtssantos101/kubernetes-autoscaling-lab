#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-keda-demo}"
APP_NAME="${APP_NAME:-messages-api}"
APP_IMAGE="${APP_IMAGE:-}"
APP_PORT="${APP_PORT:-8080}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
MAX_REPLICAS="${MAX_REPLICAS:-5}"
CPU_TARGET="${CPU_TARGET:-60}"
BUILD_IMAGE="${BUILD_IMAGE:-false}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
KIND_CLUSTER="${KIND_CLUSTER:-}"

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --build-image)
        BUILD_IMAGE=true
        if [[ -z "$APP_IMAGE" ]]; then
          APP_IMAGE="${APP_NAME}:local"
        fi
        ;;
      -h|--help)
        echo "Uso: $0 [--build-image]"
        echo "  --build-image  Constrói APP_IMAGE localmente e carrega em Kind/Minikube."
        exit 0
        ;;
      *)
        echo "ERRO: argumento desconhecido: $1" >&2
        echo "Uso: $0 [--build-image]" >&2
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

  if [[ "$BUILD_IMAGE" == "true" ]]; then
    command -v docker >/dev/null 2>&1 || {
      echo "ERRO: BUILD_IMAGE=true requer Docker instalado." >&2
      exit 1
    }
  fi
}

validate_config() {
  if [[ -z "$APP_IMAGE" ]]; then
    echo "ERRO: defina APP_IMAGE (por exemplo, APP_IMAGE=messages-api:1.0)." >&2
    exit 1
  fi

  if [[ "$BUILD_IMAGE" != "true" && "$BUILD_IMAGE" != "false" ]]; then
    echo "ERRO: BUILD_IMAGE deve ser 'true' ou 'false'." >&2
    exit 1
  fi
}

build_local_image() {
  [[ "$BUILD_IMAGE" == "true" ]] || return 0

  echo "Construindo imagem local: $APP_IMAGE"
  docker build -f "$DOCKERFILE" -t "$APP_IMAGE" "$BUILD_CONTEXT"

  if [[ "$CONTEXT" == *kind* ]]; then
    command -v kind >/dev/null 2>&1 || {
      echo "ERRO: instale kind para carregar a imagem no cluster local." >&2
      exit 1
    }
    if [[ -n "$KIND_CLUSTER" ]]; then
      kind load docker-image "$APP_IMAGE" --name "$KIND_CLUSTER"
    else
      kind load docker-image "$APP_IMAGE"
    fi
  elif [[ "$CONTEXT" == *minikube* ]]; then
    command -v minikube >/dev/null 2>&1 || {
      echo "ERRO: instale minikube para carregar a imagem no cluster local." >&2
      exit 1
    }
    minikube image load "$APP_IMAGE"
  else
    echo "AVISO: imagem construída localmente; o cluster precisa conseguir acessá-la."
  fi
}

install_cluster_dependencies() {

  helm repo add karpenter https://karpenter.sh
  helm repo update

  helm install karpenter karpenter/karpenter \
  --namespace kube-system \
  --set cloudProvider=kwok \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi

  helm repo add kedacore https://kedacore.github.io/charts
  helm repo update
  helm upgrade --install keda kedacore/keda \
    --namespace kube-system --create-namespace --wait --timeout 5m

  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
  helm repo update
  helm upgrade --install metrics-server metrics-server/metrics-server \
    --namespace kube-system --wait --timeout 5m
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
