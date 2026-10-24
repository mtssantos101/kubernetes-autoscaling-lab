MONITORING_NAMESPACE ?= monitoring
PROMETHEUS_SERVICE ?= prometheus-server
GRAFANA_SERVICE ?= grafana
PROMETHEUS_LOCAL_PORT ?= 9090
GRAFANA_LOCAL_PORT ?= 3000

.PHONY: help port-forward port-forward-prometheus port-forward-grafana

help:
	@echo "make port-forward-observability        Encaminha Prometheus e Grafana juntos"
	@echo "make port-forward-prometheus           Encaminha apenas o Prometheus"
	@echo "make port-forward-grafana              Encaminha apenas o Grafana"

port-forward-prometheus:
	kubectl port-forward -n $(MONITORING_NAMESPACE) svc/$(PROMETHEUS_SERVICE) $(PROMETHEUS_LOCAL_PORT):80

port-forward-grafana:
	kubectl port-forward -n $(MONITORING_NAMESPACE) svc/$(GRAFANA_SERVICE) $(GRAFANA_LOCAL_PORT):80

port-forward-observability:
	@set -e; \
	 kubectl port-forward -n $(MONITORING_NAMESPACE) svc/$(PROMETHEUS_SERVICE) $(PROMETHEUS_LOCAL_PORT):80 & prometheus_pid=$$!; \
	 kubectl port-forward -n $(MONITORING_NAMESPACE) svc/$(GRAFANA_SERVICE) $(GRAFANA_LOCAL_PORT):80 & grafana_pid=$$!; \
	 trap 'kill $$prometheus_pid $$grafana_pid 2>/dev/null || true; wait $$prometheus_pid $$grafana_pid 2>/dev/null || true' EXIT INT TERM; \
	 echo "Prometheus: http://localhost:$(PROMETHEUS_LOCAL_PORT)"; \
	 echo "Grafana:    http://localhost:$(GRAFANA_LOCAL_PORT) (admin/admin)"; \
	 wait
