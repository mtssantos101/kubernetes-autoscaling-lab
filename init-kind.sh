#!/bin/bash

set -e

CLUSTER_NAME="worker-cluster"
CONFIG_FILE="kind-config.yaml"

if ! command -v docker &> /dev/null; then
    echo "Erro: Docker não está instalado"
    exit 1
fi

if ! command -v kind &> /dev/null; then
    echo "Erro: Kind não está instalado"
    exit 1
fi

cat <<EOF > $CONFIG_FILE
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
    echo "O cluster '$CLUSTER_NAME' ja existe. Pulando a criação."
else
    kind create cluster --name "$CLUSTER_NAME" --config "$CONFIG_FILE"
fi

kubectl cluster-info --context "kind-$CLUSTER_NAME"

rm $CONFIG_FILE
