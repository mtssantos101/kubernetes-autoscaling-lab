#!/usr/bin/env bash
set -Eeuo pipefail

# Exemplos:
# ./load-test.sh
# TOTAL_REQUESTS=10000 CONCURRENCY=50 ./load-test.sh
# BODY_MODE=json ./load-test.sh
#
# Se API_URL for definida, o script não cria port-forward.
# Exemplo: API_URL=http://localhost:8080/messages ./load-test.sh

NAMESPACE="${NAMESPACE:-keda-demo}"
APP_NAME="${APP_NAME:-messages-api}"
APP_PORT="${APP_PORT:-8080}"
PORT_FORWARD_TIMEOUT="${PORT_FORWARD_TIMEOUT:-60}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"

TOTAL_REQUESTS="${TOTAL_REQUESTS:-5000}"
CONCURRENCY="${CONCURRENCY:-25}"
REQUEST_METHOD="${REQUEST_METHOD:-POST}"
BODY_MODE="${BODY_MODE:-json}"
API_URL="${API_URL:-}"

for cmd in kubectl curl xargs awk seq wc; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERRO: comando ausente: $cmd"
    exit 1
  }
done

if ! [[ "$TOTAL_REQUESTS" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "$CONCURRENCY" =~ ^[1-9][0-9]*$ ]]; then
  echo "TOTAL_REQUESTS e CONCURRENCY devem ser inteiros positivos."
  exit 1
fi

if ! [[ "$REQUEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "REQUEST_TIMEOUT deve ser um inteiro positivo (segundos)."
  exit 1
fi

PF_PID=""
LOAD_PID=""

cleanup() {
  if [[ -n "$LOAD_PID" ]]; then
    kill "$LOAD_PID" 2>/dev/null || true
    wait "$LOAD_PID" 2>/dev/null || true
  fi
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ -z "$API_URL" ]]; then
  API_URL="http://127.0.0.1:18080/messages"

  echo "Iniciando port-forward..."
  kubectl port-forward \
    -n "$NAMESPACE" \
    "svc/$APP_NAME" \
    "18080:$APP_PORT" \
    >/tmp/keda-load-port-forward.log 2>&1 &
  PF_PID=$!

  ready=false
  for _ in $(seq 1 "$PORT_FORWARD_TIMEOUT"); do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      cat /tmp/keda-load-port-forward.log
      echo "ERRO: não foi possível iniciar o port-forward."
      exit 1
    fi

    HTTP_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
      --max-time 1 "$API_URL" 2>/dev/null || true)"
    if [[ "$HTTP_STATUS" =~ ^[1-5][0-9][0-9]$ ]]; then
      ready=true
      break
    fi
    sleep 1
  done

  if [[ "$ready" != true ]]; then
    cat /tmp/keda-load-port-forward.log
    echo "ERRO: API não ficou acessível em $API_URL"
    exit 1
  fi
fi

export API_URL REQUEST_METHOD BODY_MODE REQUEST_TIMEOUT

RESULTS="$(mktemp)"
export RESULTS

echo
echo "URL: $API_URL"
echo "Método: $REQUEST_METHOD"
echo "Formato: $BODY_MODE"
echo "Total: $TOTAL_REQUESTS"
echo "Concorrência: $CONCURRENCY"
echo

START="$(date +%s)"

seq 1 "$TOTAL_REQUESTS" |
  xargs -P "$CONCURRENCY" -I '{}' \
    bash -c '
      id="load-$(printf "%08d" "$1")"
      url="$API_URL"
      args=(-sS -o /dev/null -w "%{http_code} %{time_total}"
            --max-time "$REQUEST_TIMEOUT")

      case "$BODY_MODE" in
        query)
          url="${url}?messageId=${id}"
          ;;
        path)
          url="${url%/}/${id}"
          ;;
        json)
          args+=(-H "Content-Type: application/json"
                 -d "{\"messageId\":\"${id}\"}")
          ;;
        raw)
          args+=(-H "Content-Type: text/plain" -d "$id")
          ;;
        *)
          echo "BODY_MODE inválido: $BODY_MODE" >&2
          exit 2
          ;;
      esac

      result="$(curl "${args[@]}" -X "$REQUEST_METHOD" "$url" 2>/dev/null)" ||
        result="000 0"

      printf "%s\n" "$result" >> "$RESULTS"
    ' _ '{}' &
LOAD_PID=$!

while kill -0 "$LOAD_PID" 2>/dev/null; do
  COMPLETED="$(wc -l < "$RESULTS")"
  printf '\rProgresso: %s/%s requisições' "$COMPLETED" "$TOTAL_REQUESTS"
  sleep 1
done

if ! wait "$LOAD_PID"; then
  echo
  echo "ERRO: houve uma falha ao executar os workers de carga."
  exit 1
fi
LOAD_PID=""
COMPLETED="$(wc -l < "$RESULTS")"
printf '\rProgresso: %s/%s requisições concluídas\n' "$COMPLETED" "$TOTAL_REQUESTS"

END="$(date +%s)"
ELAPSED=$((END - START))
[[ "$ELAPSED" -gt 0 ]] || ELAPSED=1

echo
echo "========== RESULTADO =========="

awk -v elapsed="$ELAPSED" '
  {
    status=$1
    latency=$2
    count++
    total_latency += latency

    if (status >= 200 && status < 300) success++
    else failures++

    statuses[status]++
  }
  END {
    printf "Requisições: %d\n", count
    printf "Sucesso (2xx): %d\n", success
    printf "Outras respostas/erros: %d\n", failures
    printf "Latência média: %.3f s\n",
           count ? total_latency/count : 0
    printf "Taxa média: %.2f req/s\n", count/elapsed
    print "\nCódigos HTTP:"

    for (status in statuses)
      printf "  %s: %d\n", status, statuses[status]
  }
' "$RESULTS"

echo
echo "Duração aproximada: ${ELAPSED}s"
echo
echo "Pods atuais:"
kubectl get pods -n "$NAMESPACE"

rm -f "$RESULTS"
