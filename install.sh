#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-lab}"
APP_NAME="${APP_NAME:-messages-api}"
APP_IMAGE="${APP_IMAGE:-}"
APP_PORT="${APP_PORT:-8080}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
MAX_REPLICAS="${MAX_REPLICAS:-5}"
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
    --namespace kube-system --wait --timeout 5m

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

install_local_kafka() {
  [[ "$LOCAL_MODE" == "true" ]] || return 0

  KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-kafka.${NAMESPACE}.svc.cluster.local:9092}"
  NAMESPACE="$NAMESPACE" envsubst <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: ${NAMESPACE}
spec:
  selector:
    app: kafka
  ports:
    - name: broker
      port: 9092
      targetPort: 9092
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kafka
  template:
    metadata:
      labels:
        app: kafka
    spec:
      containers:
        - name: kafka
          image: apache/kafka:4.1.0
          ports:
            - name: broker
              containerPort: 9092
            - name: controller
              containerPort: 9093
          env:
            - name: KAFKA_NODE_ID
              value: "1"
            - name: KAFKA_PROCESS_ROLES
              value: broker,controller
            - name: KAFKA_LISTENERS
              value: PLAINTEXT://:9092,CONTROLLER://:9093
            - name: KAFKA_ADVERTISED_LISTENERS
              value: PLAINTEXT://kafka.${NAMESPACE}.svc.cluster.local:9092
            - name: KAFKA_CONTROLLER_LISTENER_NAMES
              value: CONTROLLER
            - name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP
              value: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
            - name: KAFKA_CONTROLLER_QUORUM_VOTERS
              value: 1@localhost:9093
            - name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR
              value: "1"
            - name: KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR
              value: "1"
            - name: KAFKA_TRANSACTION_STATE_LOG_MIN_ISR
              value: "1"
            - name: KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS
              value: "0"
            - name: KAFKA_NUM_PARTITIONS
              value: "3"
          readinessProbe:
            exec:
              command:
                - /opt/kafka/bin/kafka-broker-api-versions.sh
                - --bootstrap-server
                - localhost:9092
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 12
YAML

  echo "Aguardando o Kafka local..."
  kubectl rollout status deployment/kafka -n "$NAMESPACE" --timeout=180s
}

deploy_application() {
  APP_IMAGE="$APP_IMAGE" \
  KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-localhost:9092}" \
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
          env:
            - name: KAFKA_BOOTSTRAP_SERVERS
              value: ${KAFKA_BOOTSTRAP_SERVERS}
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
  install_local_kafka
  deploy_application
  wait_for_deployment
}

main "$@"
