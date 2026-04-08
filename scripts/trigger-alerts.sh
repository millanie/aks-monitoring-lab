#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# trigger-alerts.sh
# 데모 시나리오별 알림 트리거 + 실시간 모니터링
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="demo-app"

usage() {
  echo "Usage: $0 <scenario>"
  echo ""
  echo "Available scenarios:"
  echo "  1 | cpu        - Pod CPU 과부하 시뮬레이션"
  echo "  2 | oom        - OOMKilled 시뮬레이션"
  echo "  3 | errors     - HTTP 5xx 에러 급증 시뮬레이션"
  echo "  4 | crashloop  - CrashLoopBackOff 시뮬레이션"
  echo "  5 | node       - Node drain 시뮬레이션"
  echo "  all            - 모든 시나리오 순차 실행"
  echo "  status         - 현재 알림 상태 확인"
  echo "  cleanup        - 테스트 리소스 정리"
  exit 1
}

wait_and_check() {
  local msg="$1"
  local seconds="${2:-30}"
  echo -e "${YELLOW}⏳ $msg ($seconds초 대기)${NC}"
  sleep "$seconds"
}

check_alerts() {
  echo -e "\n${BLUE}📊 현재 Pod 상태:${NC}"
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | head -10

  echo -e "\n${BLUE}📊 최근 이벤트:${NC}"
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5

  echo -e "\n${BLUE}📊 Azure Monitor 알림 상태:${NC}"
  az monitor alert list --output table 2>/dev/null | head -10 || \
    echo "  (az monitor alert list 로 확인하세요)"
}

# ─── Scenario 1: CPU Stress ────────────────────────────────────────────────
scenario_cpu() {
  echo -e "\n${RED}═══════════════════════════════════════════${NC}"
  echo -e "${RED} 시나리오 1: CPU 과부하 시뮬레이션${NC}"
  echo -e "${RED}═══════════════════════════════════════════${NC}"
  echo -e "트리거 알림: NodeCPUHighUtilization, ContainerCPUThrottled"
  echo ""

  kubectl delete job cpu-stress-test -n "$NAMESPACE" --ignore-not-found=true

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: cpu-stress-test
  namespace: $NAMESPACE
  labels:
    scenario: cpu-stress
spec:
  template:
    metadata:
      labels:
        scenario: cpu-stress
    spec:
      containers:
      - name: stress
        image: polinux/stress
        command: ["stress"]
        args: ["--cpu", "4", "--timeout", "300s"]
        resources:
          requests:
            cpu: "500m"
            memory: "128Mi"
          limits:
            cpu: "2"
            memory: "256Mi"
      restartPolicy: Never
  backoffLimit: 0
EOF

  echo -e "${GREEN}✅ CPU stress Job 배포 완료${NC}"
  echo "   - 4 CPU workers, 5분간 실행 후 자동 종료"
  echo "   - Grafana에서 '노드별 CPU 사용률' 패널 확인"
}

# ─── Scenario 2: OOM ──────────────────────────────────────────────────────
scenario_oom() {
  echo -e "\n${RED}═══════════════════════════════════════════${NC}"
  echo -e "${RED} 시나리오 2: OOMKilled 시뮬레이션${NC}"
  echo -e "${RED}═══════════════════════════════════════════${NC}"
  echo -e "트리거 알림: PodOOMKilled, alert-oom-killed-pods"
  echo ""

  kubectl delete job memory-bomb -n "$NAMESPACE" --ignore-not-found=true

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: memory-bomb
  namespace: $NAMESPACE
  labels:
    scenario: oom-test
spec:
  template:
    metadata:
      labels:
        scenario: oom-test
    spec:
      containers:
      - name: memory-bomb
        image: polinux/stress
        command: ["stress"]
        args: ["--vm", "1", "--vm-bytes", "512M", "--timeout", "60s"]
        resources:
          requests:
            memory: "64Mi"
          limits:
            memory: "128Mi"
      restartPolicy: Never
  backoffLimit: 2
EOF

  echo -e "${GREEN}✅ Memory bomb Job 배포 완료${NC}"
  echo "   - 512MB 할당 시도 (limit: 128Mi) → OOMKilled 예상"
  echo "   - kubectl get pods -n $NAMESPACE -w 로 OOMKilled 확인"
}

# ─── Scenario 3: HTTP Errors ──────────────────────────────────────────────
scenario_errors() {
  echo -e "\n${RED}═══════════════════════════════════════════${NC}"
  echo -e "${RED} 시나리오 3: HTTP 5xx 에러 급증 시뮬레이션${NC}"
  echo -e "${RED}═══════════════════════════════════════════${NC}"
  echo -e "트리거 알림: HighHTTPErrorRate, OrderFailureRateHigh"
  echo ""

  # 에러 모드 활성화
  echo "  에러 모드 활성화 (50% 에러율)..."
  kubectl exec -n "$NAMESPACE" deploy/sample-app -- \
    curl -s -X POST "http://localhost:8080/api/toggle-errors?rate=0.5" || true
  echo ""

  # 트래픽 생성
  echo "  트래픽 생성 중 (200 요청)..."
  kubectl delete pod load-gen -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null
  kubectl run load-gen -n "$NAMESPACE" --rm -i --restart=Never --image=busybox -- sh -c '
    for i in $(seq 1 200); do
      wget -q -O- http://sample-app/api/order -T 5 --method=POST 2>/dev/null
      sleep 0.05
    done
    echo "DONE: 200 requests sent"
  ' &

  echo -e "${GREEN}✅ 에러 주입 + 트래픽 생성 시작${NC}"
  echo "   - Grafana에서 'HTTP 5xx 에러율' 패널 확인"
  echo "   - 5분 후 자동으로 알림 발생 예상"

  wait_and_check "트래픽 생성 완료 대기" 15

  # 에러 모드 비활성화
  echo "  에러 모드 비활성화..."
  kubectl exec -n "$NAMESPACE" deploy/sample-app -- \
    curl -s -X POST "http://localhost:8080/api/toggle-errors" || true
  echo -e "${GREEN}  에러 모드 OFF${NC}"
}

# ─── Scenario 4: CrashLoop ───────────────────────────────────────────────
scenario_crashloop() {
  echo -e "\n${RED}═══════════════════════════════════════════${NC}"
  echo -e "${RED} 시나리오 4: CrashLoopBackOff 시뮬레이션${NC}"
  echo -e "${RED}═══════════════════════════════════════════${NC}"
  echo -e "트리거 알림: PodCrashLoopBackOff, alert-container-restart-anomaly"
  echo ""

  kubectl delete deployment crashloop-demo -n "$NAMESPACE" --ignore-not-found=true

  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: crashloop-demo
  namespace: $NAMESPACE
  labels:
    scenario: crashloop
spec:
  replicas: 2
  selector:
    matchLabels:
      app: crashloop-demo
  template:
    metadata:
      labels:
        app: crashloop-demo
        scenario: crashloop
    spec:
      containers:
      - name: bad-app
        image: busybox
        command: ["/bin/sh", "-c", "echo 'Starting...'; sleep 5; echo 'Crashing!'; exit 1"]
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "100m"
            memory: "128Mi"
EOF

  echo -e "${GREEN}✅ CrashLoop Deployment 배포 완료${NC}"
  echo "   - 5초 후 crash → 반복 재시작 → CrashLoopBackOff"
  echo "   - kubectl get pods -n $NAMESPACE -w 로 상태 확인"
}

# ─── Scenario 5: Node Drain ──────────────────────────────────────────────
scenario_node() {
  echo -e "\n${RED}═══════════════════════════════════════════${NC}"
  echo -e "${RED} 시나리오 5: Node Drain 시뮬레이션${NC}"
  echo -e "${RED}═══════════════════════════════════════════${NC}"
  echo -e "트리거 알림: NodeNotReady (cordon), PodPendingTooLong"
  echo ""

  NODE_NAME=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -z "$NODE_NAME" ]]; then
    echo -e "${YELLOW}⚠️  워커 노드를 찾을 수 없습니다. 스킵합니다.${NC}"
    return
  fi

  echo "  대상 노드: $NODE_NAME"
  echo ""

  read -p "  ⚠️  이 노드를 cordon + drain 하시겠습니까? (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "  스킵합니다."
    return
  fi

  echo "  Cordoning node..."
  kubectl cordon "$NODE_NAME"

  echo "  Draining node..."
  kubectl drain "$NODE_NAME" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --grace-period=30 \
    --timeout=120s || true

  echo -e "${GREEN}✅ Node drain 완료${NC}"
  echo "   - kubectl get nodes 로 SchedulingDisabled 확인"
  echo "   - Pod들이 다른 노드로 재배치되는지 확인"
  echo ""
  echo "  복구 명령:"
  echo "    kubectl uncordon $NODE_NAME"
}

# ─── Cleanup ──────────────────────────────────────────────────────────────
cleanup() {
  echo -e "\n${BLUE}🧹 테스트 리소스 정리${NC}"

  echo "  Deleting test Jobs..."
  kubectl delete job cpu-stress-test memory-bomb -n "$NAMESPACE" --ignore-not-found=true

  echo "  Deleting crashloop deployment..."
  kubectl delete deployment crashloop-demo -n "$NAMESPACE" --ignore-not-found=true

  echo "  Deleting load-gen pod..."
  kubectl delete pod load-gen -n "$NAMESPACE" --ignore-not-found=true

  # Uncordon any cordoned nodes
  echo "  Uncordoning any cordoned nodes..."
  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    if kubectl get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null | grep -q true; then
      echo "    Uncordoning $node"
      kubectl uncordon "$node"
    fi
  done

  # 에러 모드 비활성화
  echo "  Disabling error mode..."
  kubectl exec -n "$NAMESPACE" deploy/sample-app -- \
    curl -s -X POST "http://localhost:8080/api/toggle-errors" 2>/dev/null || true

  echo -e "${GREEN}✅ 정리 완료${NC}"
}

# ─── Main ─────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  usage
fi

case "$1" in
  1|cpu)       scenario_cpu ;;
  2|oom)       scenario_oom ;;
  3|errors)    scenario_errors ;;
  4|crashloop) scenario_crashloop ;;
  5|node)      scenario_node ;;
  all)
    scenario_cpu
    wait_and_check "다음 시나리오 준비" 10
    scenario_oom
    wait_and_check "다음 시나리오 준비" 10
    scenario_errors
    wait_and_check "다음 시나리오 준비" 10
    scenario_crashloop
    echo ""
    echo -e "${YELLOW}💡 시나리오 5(Node drain)는 수동 확인이 필요하므로 별도 실행하세요:${NC}"
    echo "   ./scripts/trigger-alerts.sh 5"
    ;;
  status)      check_alerts ;;
  cleanup)     cleanup ;;
  *)           usage ;;
esac

echo ""
echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo -e "${BLUE} 확인 방법:${NC}"
echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo "  1. Grafana 대시보드: \${GRAFANA_URL}"
echo "  2. Azure Portal → Monitor → Alerts"
echo "  3. kubectl get pods -n $NAMESPACE -w"
echo "  4. kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'"
echo ""
