# Kafka Worker

## Kubernetes local

Crie o cluster Kind e instale a aplicação com Kafka local, KEDA e observabilidade:

```bash
./init-kind.sh
./install.sh --local
```

Para usar uma imagem já disponível no cluster, defina `APP_IMAGE` e execute `./install.sh`.
As configurações podem ser substituídas pelas variáveis documentadas no início de `install.sh`.

## Estrutura de deploy

- `charts/messages-api`: Deployment, Service, probes, scrape Prometheus e ScaledObject KEDA.
- `charts/kafka`: Kafka KRaft para desenvolvimento local.
- `charts/observability`: dashboard provisionado pelo Grafana.
- `config/helm/observability`: overrides dos charts externos de Grafana, Loki e Alloy.
- `config/helm/karpenter-kwok.yaml`: override do chart externo do provider KWOK.
- `charts/karpenter-kwok-config`: NodeClass KWOK e NodePool do Karpenter em templates Helm separados.
- `config/helm/metrics-server-local.yaml`: configuração local do chart externo metrics-server.
- `config/kind/cluster.yaml`: topologia do cluster Kind.

Os scripts coordenam a instalação e passam configurações aos charts; os templates Kubernetes ficam separados dos scripts.

Para abrir Prometheus e Grafana localmente:

```bash
make port-forward-observability
```
