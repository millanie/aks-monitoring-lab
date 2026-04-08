# AKS Monitoring Demo Scenarios

## 개요
이 문서는 AKS + Managed Prometheus + Managed Grafana + Azure Monitor 통합 환경에서
알림이 정상적으로 동작하는지 검증하기 위한 **5가지 데모 시나리오**를 설명합니다.

---

## 시나리오 1: Pod CPU 임계값 초과 알림

**목적**: 노드/컨테이너 CPU 과부하 시 Prometheus Alert → Azure Monitor 경로 확인

**트리거 방법**:
```bash
# CPU stress Job 배포
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: cpu-stress-test
  namespace: demo-app
spec:
  template:
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
```

**확인 포인트**:
1. **Grafana**: "노드별 CPU 사용률" 패널에서 급등 확인
2. **Prometheus Alert**: `NodeCPUHighUtilization` 또는 `ContainerCPUThrottled` firing
3. **Azure Monitor**: Alert → Action Group → Email 수신 확인
4. **자동 해소**: stress Job 종료(5분) 후 알림 resolved 확인

**예상 타임라인**:
- 0분: Job 배포
- ~3분: Grafana 대시보드에서 CPU 급등 확인
- ~5분: Prometheus Alert firing 상태 전환
- ~5분: Azure Monitor에서 알림 생성 → Email 발송
- ~10분: Job 종료 후 알림 자동 해소

---

## 시나리오 2: Pod OOMKilled 알림

**목적**: 메모리 초과로 인한 OOMKilled 감지 및 알림 경로 확인

**트리거 방법**:
```bash
# Memory bomb Job - 메모리 limit을 초과하는 할당
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: memory-bomb
  namespace: demo-app
spec:
  template:
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
```

**확인 포인트**:
1. `kubectl get pods -n demo-app` → OOMKilled 상태 확인
2. **Prometheus**: `PodOOMKilled` alert firing
3. **Azure Monitor**: `alert-oom-killed-pods` (Log-based) 알림 발생
4. **Grafana**: Container Restarts 패널 증가 확인

---

## 시나리오 3: HTTP 5xx 에러 급증 알림

**목적**: 애플리케이션 에러율 증가 시 커스텀 메트릭 기반 알림 확인

**트리거 방법**:
```bash
# 1. 에러 모드 활성화 (50% 에러율)
kubectl exec -n demo-app deploy/sample-app -- \
  curl -s -X POST "http://localhost:8080/api/toggle-errors?rate=0.5"

# 2. 트래픽 생성 (500 요청)
kubectl run -n demo-app load-gen --rm -i --image=busybox -- sh -c '
  for i in $(seq 1 500); do
    wget -q -O- http://sample-app/api/order -T 5 --method=POST 2>/dev/null
    sleep 0.1
  done
'

# 3. 에러 모드 비활성화
kubectl exec -n demo-app deploy/sample-app -- \
  curl -s -X POST "http://localhost:8080/api/toggle-errors"
```

**확인 포인트**:
1. **Grafana**: "HTTP 5xx 에러율" 패널에서 에러율 급증 확인
2. **Grafana**: "HTTP 요청 처리율" 패널에서 5xx 응답 비율 증가
3. **Prometheus**: `HighHTTPErrorRate` alert firing (5% 초과 시)
4. **Prometheus**: `OrderFailureRateHigh` alert firing (10% 초과 시)
5. **Azure Monitor**: Action Group 통해 알림 수신

---

## 시나리오 4: Pod CrashLoopBackOff 알림

**목적**: 잘못된 이미지 배포로 인한 CrashLoopBackOff 감지 및 알림 확인

**트리거 방법**:
```bash
# 존재하지 않는 이미지로 Deployment 생성
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: crashloop-demo
  namespace: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: crashloop-demo
  template:
    metadata:
      labels:
        app: crashloop-demo
    spec:
      containers:
      - name: bad-app
        image: sample-app:nonexistent-tag
        command: ["/bin/sh", "-c", "exit 1"]
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "100m"
            memory: "128Mi"
EOF
```

**확인 포인트**:
1. `kubectl get pods -n demo-app -w` → CrashLoopBackOff 확인
2. **Prometheus**: `PodCrashLoopBackOff` alert firing (15분 내 3회 재시작)
3. **Azure Monitor**: `alert-container-restart-anomaly` 알림 발생
4. **Grafana**: "Container Restarts (15m)" stat 증가

**정리**:
```bash
kubectl delete deployment crashloop-demo -n demo-app
```

---

## 시나리오 5: Node NotReady 시뮬레이션

**목적**: 노드 장애 상황에서의 알림 및 워크로드 재배치 확인

**트리거 방법**:
```bash
# 노드 목록 확인
kubectl get nodes

# 워커 노드 하나를 cordon + drain (스케줄링 차단)
NODE_NAME=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
echo "Cordoning node: $NODE_NAME"

kubectl cordon "$NODE_NAME"
kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30
```

**확인 포인트**:
1. `kubectl get nodes` → SchedulingDisabled 상태 확인
2. **Grafana**: "노드 수" stat 변화 확인
3. **Prometheus**: `NodeNotReady` 알림 (cordon만으로는 NotReady는 아니지만 drain으로 Pod 재배치 확인)
4. **Azure Monitor**: `alert-failed-pod-scheduling` (노드 부족으로 Pending Pod 발생 시)
5. Pod들이 다른 노드로 자동 재배치되는지 확인

**복구**:
```bash
kubectl uncordon "$NODE_NAME"
```

---

## 알림 흐름 확인 체크리스트

각 시나리오 후 아래 경로를 통해 End-to-End 알림 흐름을 확인하세요:

```
[메트릭 수집]
  AKS Pod → ama-metrics DaemonSet → Azure Monitor Workspace (Managed Prometheus)

[알림 평가]
  Prometheus Rule Group (aks-node-alerts, aks-pod-alerts, aks-app-alerts)
    → 조건 충족 시 firing
  Azure Monitor Scheduled Query Rules (Log Analytics 기반)
    → KQL 쿼리 결과 기반 알림

[알림 전달]
  Firing Alert → Action Group (ag-aks-monitoring)
    → Email 발송
    → (선택) Webhook / Logic App / Teams / Slack

[시각화]
  Managed Grafana 대시보드에서 실시간 메트릭 확인
  Azure Portal → Monitor → Alerts 에서 중앙 알림 관리
```

## Azure Portal에서 확인

1. **Azure Monitor > Alerts**: 모든 알림 중앙 관리
2. **Azure Monitor > Metrics**: Prometheus 메트릭 쿼리
3. **Managed Grafana**: 커스텀 대시보드 (자동 링크된 Prometheus 데이터소스)
4. **Log Analytics**: Container Insights 로그 쿼리
