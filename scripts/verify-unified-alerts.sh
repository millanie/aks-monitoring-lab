#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# verify-unified-alerts.sh
#
# Prometheus Rule Group + Azure Monitor 알림이 Azure Monitor > Alerts 메뉴에서
# 통합 조회되는지 검증하는 스크립트.
#
# 1) 빠르게 fire 되는 시나리오를 트리거 (CrashLoop + OOM)
# 2) Azure Monitor Alerts REST API로 fired alert을 polling
# 3) alert source 별로 분류하여 통합 조회 가능 여부를 확인
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

NAMESPACE="demo-app"
POLL_INTERVAL=30
MAX_POLLS=20  # 최대 10분 대기

# ─── Load Environment ──────────────────────────────────────────────────────
if [[ -f /tmp/aks-monitoring-env.sh ]]; then
  source /tmp/aks-monitoring-env.sh
  echo -e "${GREEN}✅ Loaded environment from /tmp/aks-monitoring-env.sh${NC}"
else
  echo -e "${YELLOW}⚠️  /tmp/aks-monitoring-env.sh not found.${NC}"
  echo "   Set RESOURCE_GROUP manually or run infra/setup-monitoring-infra.sh first."
  echo ""
  read -rp "   RESOURCE_GROUP: " RESOURCE_GROUP
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  trigger     시나리오 트리거 (CrashLoop + OOM → Prometheus & Azure Monitor alert 모두 발생)
  poll        Azure Monitor Alerts API를 polling하여 fired alert 통합 조회
  query       현재 fired/resolved alert을 즉시 한 번 조회
  check-rules 배포된 alert rule 목록을 source type별로 출력
  full        trigger → poll 순차 실행 (전체 검증)
  cleanup     테스트 리소스 정리

EOF
  exit 1
}

# ─── Helper: Query fired alerts via REST API ───────────────────────────────
query_fired_alerts() {
  local time_range="${1:-1h}"
  local start_time
  start_time=$(date -u -d "-${time_range}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v-"${time_range}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Azure Monitor Alerts API - 리소스 그룹 내 모든 fired alerts 조회
  az rest \
    --method get \
    --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.AlertsManagement/alerts?api-version=2024-01-01-preview&targetResourceGroup=${RESOURCE_GROUP}&timeRange=${time_range}" \
    2>/dev/null
}

# ─── Command: check-rules ─────────────────────────────────────────────────
cmd_check_rules() {
  echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  배포된 Alert Rule 목록 (Source Type별)${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"

  # 1. Prometheus Rule Groups
  echo -e "\n${CYAN}📌 [Prometheus Rule Groups] (Microsoft.AlertsManagement/prometheusRuleGroups)${NC}"
  echo -e "   Azure Portal 위치: Azure Monitor workspace > Prometheus rule groups (별도 메뉴)"
  echo -e "   ※ Monitor > Alerts > Alert rules에는 표시되지 않음 (별도 리소스 타입)"
  echo ""
  az rest --method get \
    --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.AlertsManagement/prometheusRuleGroups?api-version=2023-03-01" \
    --query 'value[].{Name:name, RuleCount:length(properties.rules), Description:properties.description}' \
    -o table 2>/dev/null || echo "   (조회 실패 - 배포 확인 필요)"

  # 개별 rule 이름 출력
  echo ""
  az rest --method get \
    --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.AlertsManagement/prometheusRuleGroups?api-version=2023-03-01" \
    --query 'value[].properties.rules[].alert' -o tsv 2>/dev/null | while read -r rule; do
      echo -e "   ${YELLOW}⚡ ${rule}${NC}"
    done

  # 2. Log-based Alert Rules (Scheduled Query Rules)
  echo -e "\n${CYAN}📌 [Log-based Alert Rules] (Microsoft.Insights/scheduledQueryRules)${NC}"
  echo -e "   Azure Portal 위치: Monitor > Alerts > Alert rules > Filter: Signal type = Log"
  echo ""
  az monitor scheduled-query list \
    --resource-group "$RESOURCE_GROUP" \
    --query '[].{Name:name, DisplayName:displayName, Severity:severity, Enabled:enabled}' \
    -o table 2>/dev/null || echo "   (조회 실패)"

  # 3. Metric Alert Rules
  echo -e "\n${CYAN}📌 [Metric Alert Rules] (Microsoft.Insights/metricAlerts)${NC}"
  echo -e "   Azure Portal 위치: Monitor > Alerts > Alert rules > Filter: Signal type = Metric"
  echo ""
  az monitor metrics alert list \
    --resource-group "$RESOURCE_GROUP" \
    --query '[].{Name:name, Description:description, Severity:severity, Enabled:enabled}' \
    -o table 2>/dev/null || echo "   (조회 실패)"

  echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}💡 위 모든 rule에서 발생한 alert은 Azure Monitor > Alerts 에서 통합 조회됩니다.${NC}"
  echo -e "${GREEN}   Portal 경로: Monitor > Alerts > 필터 없이 전체 보기${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─── Command: trigger ──────────────────────────────────────────────────────
cmd_trigger() {
  echo -e "\n${BOLD}${RED}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Alert 트리거: Prometheus + Azure Monitor 동시 발생 시나리오${NC}"
  echo -e "${BOLD}${RED}══════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  이 스크립트는 다음 alert들을 동시에 트리거합니다:"
  echo ""
  echo -e "  ${YELLOW}[Prometheus Rules]${NC}"
  echo "    - PodCrashLoopBackOff  (kube_pod_container_status_restarts_total)"
  echo "    - PodOOMKilled         (kube_pod_container_status_last_terminated_reason)"
  echo ""
  echo -e "  ${YELLOW}[Azure Monitor - Log Query]${NC}"
  echo "    - alert-container-restart-anomaly (KubePodInventory)"
  echo "    - alert-oom-killed-pods          (KubeEvents)"
  echo ""

  # Ensure namespace exists
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

  # ── Scenario A: CrashLoopBackOff ──
  echo -e "${RED}▶ [A] CrashLoopBackOff 트리거${NC}"
  kubectl delete deployment crashloop-verify -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: crashloop-verify
  namespace: ${NAMESPACE}
  labels:
    scenario: unified-alert-verify
spec:
  replicas: 2
  selector:
    matchLabels:
      app: crashloop-verify
  template:
    metadata:
      labels:
        app: crashloop-verify
        scenario: unified-alert-verify
    spec:
      containers:
      - name: crash-app
        image: busybox
        command: ["/bin/sh", "-c", "echo 'Starting...'; sleep 3; echo 'Crashing!'; exit 1"]
        resources:
          requests:
            cpu: "50m"
            memory: "32Mi"
          limits:
            cpu: "100m"
            memory: "64Mi"
EOF
  echo -e "  ${GREEN}✅ CrashLoop Deployment 배포 완료 (3초 주기 crash)${NC}"

  # ── Scenario B: OOMKilled ──
  echo -e "\n${RED}▶ [B] OOMKilled 트리거${NC}"
  kubectl delete job oom-verify -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: oom-verify
  namespace: ${NAMESPACE}
  labels:
    scenario: unified-alert-verify
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: oom-verify
        scenario: unified-alert-verify
    spec:
      containers:
      - name: oom-app
        image: polinux/stress
        command: ["stress"]
        args: ["--vm", "1", "--vm-bytes", "256M", "--timeout", "60s"]
        resources:
          requests:
            memory: "32Mi"
          limits:
            memory: "64Mi"
      restartPolicy: Never
EOF
  echo -e "  ${GREEN}✅ OOM Job 배포 완료 (256MB 할당 시도, limit 64Mi)${NC}"

  echo ""
  echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════${NC}"
  echo -e "  트리거 완료. Alert 발생까지 약 5~15분 소요됩니다."
  echo -e ""
  echo -e "  Prometheus rules: for 절(PT1M~PT5M) 경과 후 fire"
  echo -e "  Azure Monitor log rules: evaluationFrequency(PT5M) 주기로 평가"
  echo -e ""
  echo -e "  다음 명령으로 alert 통합 조회를 시작하세요:"
  echo -e "    ${CYAN}./scripts/verify-unified-alerts.sh poll${NC}"
  echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════${NC}"
}

# ─── Command: query ────────────────────────────────────────────────────────
cmd_query() {
  echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Azure Monitor > Alerts 통합 조회 (현재 시점)${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
  echo ""

  local raw_alerts
  raw_alerts=$(query_fired_alerts "1h")

  if [[ -z "$raw_alerts" || "$raw_alerts" == "null" ]]; then
    echo -e "  ${YELLOW}알림이 없습니다 (최근 1시간).${NC}"
    return
  fi

  local total
  total=$(echo "$raw_alerts" | jq '.value | length')
  echo -e "  ${BOLD}총 ${total}개 alert 발견 (최근 1시간)${NC}"
  echo ""

  # Prometheus-sourced alerts
  echo -e "  ${CYAN}── Prometheus Rule Group 소스 ──${NC}"
  echo "$raw_alerts" | jq -r '
    .value[]
    | select(.properties.essentials.monitorCondition != null)
    | select(.properties.essentials.signalType == "Metric" or (.properties.essentials.targetResourceType // "" | test("prometheusRuleGroups"; "i")))
    | "    \(.properties.essentials.severity // "N/A") | \(.properties.essentials.monitorCondition) | \(.name // "unknown") | \(.properties.essentials.startDateTime // "N/A")"
  ' 2>/dev/null | head -20 || echo "    (없음)"

  echo ""

  # Log-based alerts
  echo -e "  ${CYAN}── Log-based Alert (Scheduled Query) 소스 ──${NC}"
  echo "$raw_alerts" | jq -r '
    .value[]
    | select(.properties.essentials.signalType == "Log")
    | "    \(.properties.essentials.severity // "N/A") | \(.properties.essentials.monitorCondition) | \(.name // "unknown") | \(.properties.essentials.startDateTime // "N/A")"
  ' 2>/dev/null | head -20 || echo "    (없음)"

  echo ""

  # Metric alerts
  echo -e "  ${CYAN}── Platform Metric Alert 소스 ──${NC}"
  echo "$raw_alerts" | jq -r '
    .value[]
    | select(.properties.essentials.signalType == "Metric")
    | select((.properties.essentials.targetResourceType // "") | test("prometheusRuleGroups"; "i") | not)
    | "    \(.properties.essentials.severity // "N/A") | \(.properties.essentials.monitorCondition) | \(.name // "unknown") | \(.properties.essentials.startDateTime // "N/A")"
  ' 2>/dev/null | head -20 || echo "    (없음)"

  echo ""

  # Summary table
  echo -e "  ${BOLD}── 전체 Alert 요약 (signalType별) ──${NC}"
  echo "$raw_alerts" | jq -r '
    [.value[].properties.essentials.signalType]
    | group_by(.)
    | map({type: .[0], count: length})
    | .[]
    | "    \(.type): \(.count)건"
  ' 2>/dev/null || echo "    (파싱 실패)"

  echo ""
  echo -e "  ${GREEN}💡 Azure Portal에서 확인: Monitor > Alerts${NC}"
  echo -e "  ${GREEN}   Resource Group 필터: ${RESOURCE_GROUP}${NC}"
}

# ─── Command: poll ─────────────────────────────────────────────────────────
cmd_poll() {
  echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Alert Polling 시작 (${POLL_INTERVAL}초 간격, 최대 ${MAX_POLLS}회)${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
  echo ""

  local found_prometheus=false
  local found_logquery=false

  for ((i=1; i<=MAX_POLLS; i++)); do
    echo -e "${YELLOW}[${i}/${MAX_POLLS}] $(date '+%H:%M:%S') - Azure Monitor Alerts 조회 중...${NC}"

    # K8s 상태 빠르게 확인
    echo -e "  ${BLUE}Pod 상태:${NC}"
    kubectl get pods -n "$NAMESPACE" -l scenario=unified-alert-verify --no-headers 2>/dev/null | sed 's/^/    /'
    echo ""

    # Azure Monitor Alerts 조회
    local raw_alerts
    raw_alerts=$(query_fired_alerts "1h" 2>/dev/null || echo "")

    if [[ -n "$raw_alerts" && "$raw_alerts" != "null" ]]; then
      local total
      total=$(echo "$raw_alerts" | jq '.value | length' 2>/dev/null || echo "0")

      if [[ "$total" -gt 0 ]]; then
        echo -e "  ${GREEN}🔔 ${total}개 alert 발견!${NC}"

        # Check for Prometheus-sourced
        local prom_count
        prom_count=$(echo "$raw_alerts" | jq '[.value[] | select((.properties.essentials.targetResourceType // "") | test("prometheusRuleGroups"; "i"))] | length' 2>/dev/null || echo "0")
        if [[ "$prom_count" -gt 0 ]]; then
          found_prometheus=true
          echo -e "  ${GREEN}  ✅ Prometheus Rule alert: ${prom_count}건${NC}"
        fi

        # Check for Log-based
        local log_count
        log_count=$(echo "$raw_alerts" | jq '[.value[] | select(.properties.essentials.signalType == "Log")] | length' 2>/dev/null || echo "0")
        if [[ "$log_count" -gt 0 ]]; then
          found_logquery=true
          echo -e "  ${GREEN}  ✅ Log Query alert: ${log_count}건${NC}"
        fi

        # Both found → verified
        if $found_prometheus && $found_logquery; then
          echo ""
          echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}"
          echo -e "${BOLD}${GREEN}  ✅ 검증 완료: Prometheus + Azure Monitor alert 모두 통합 조회 확인!${NC}"
          echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}"
          echo ""
          cmd_query
          return 0
        fi
      else
        echo -e "  ${YELLOW}  아직 fired alert 없음${NC}"
      fi
    else
      echo -e "  ${YELLOW}  API 응답 없음 (권한 또는 네트워크 확인)${NC}"
    fi

    if [[ $i -lt $MAX_POLLS ]]; then
      echo -e "  ${YELLOW}⏳ ${POLL_INTERVAL}초 후 재시도...${NC}\n"
      sleep "$POLL_INTERVAL"
    fi
  done

  echo ""
  echo -e "${YELLOW}⚠️  최대 polling 횟수 도달. 현재까지 결과:${NC}"
  echo -e "   Prometheus alert 감지: $($found_prometheus && echo '✅ 확인' || echo '❌ 미감지')"
  echo -e "   Log Query alert 감지:  $($found_logquery && echo '✅ 확인' || echo '❌ 미감지')"
  echo ""
  echo -e "   ${CYAN}수동 확인: Azure Portal > Monitor > Alerts > Resource Group: ${RESOURCE_GROUP}${NC}"
  echo -e "   ${CYAN}또는: ./scripts/verify-unified-alerts.sh query  (수동 재조회)${NC}"
}

# ─── Command: cleanup ──────────────────────────────────────────────────────
cmd_cleanup() {
  echo -e "\n${BLUE}🧹 검증용 테스트 리소스 정리${NC}"

  echo "  Deleting crashloop-verify deployment..."
  kubectl delete deployment crashloop-verify -n "$NAMESPACE" --ignore-not-found=true

  echo "  Deleting oom-verify job..."
  kubectl delete job oom-verify -n "$NAMESPACE" --ignore-not-found=true

  echo -e "${GREEN}✅ 정리 완료${NC}"
}

# ─── Command: full ─────────────────────────────────────────────────────────
cmd_full() {
  cmd_check_rules
  echo ""
  cmd_trigger
  echo ""
  echo -e "${YELLOW}⏳ 초기 대기 60초 (Prometheus for 절 + 첫 평가 주기)...${NC}"
  sleep 60
  cmd_poll
}

# ─── Main ──────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  usage
fi

case "$1" in
  trigger)     cmd_trigger ;;
  poll)        cmd_poll ;;
  query)       cmd_query ;;
  check-rules) cmd_check_rules ;;
  full)        cmd_full ;;
  cleanup)     cmd_cleanup ;;
  *)           usage ;;
esac
