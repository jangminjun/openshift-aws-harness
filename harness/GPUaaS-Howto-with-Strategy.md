# GPUaaS Howto & Strategy

OpenShift + OpenShift AI + NVIDIA GPU 환경에서 실측 검증된 GPUaaS 운영
시나리오 모음입니다. 각 시나리오는 **목적 → 구성 → 장점/단점 → 테스트 결과
→ 시나리오 시사점** 순서로 정리했으며, 최종적으로 확정된 구성과 실측
결과만 담았습니다.

**테스트 환경**:

| 구성 요소 | 버전 |
|---|---|
| Red Hat OpenShift Container Platform | 4.22.10 |
| Red Hat OpenShift AI (RHOAI, `rhods-operator`) | 2.25.8 |
| NVIDIA GPU Operator (Certified) | 26.7.0 |
| Node Feature Discovery (NFD) Operator | 4.22.0 |
| Red Hat OpenShift Serverless | 1.37.1 |
| Red Hat OpenShift Service Mesh (Istio 기반) | 2.6.17 |
| OpenShift Custom Metrics Autoscaler (KEDA 기반) | 2.19.0 |
| Grafana Operator (community, 독립 모니터링 스택) | 5.24.0 |
| Prometheus Operator (community, 독립 모니터링 스택) | 0.56.3 |
| Loki Operator | 6.6.0 |
| Red Hat OpenShift Logging (Cluster Logging Operator) | 6.6.0 |
| MinIO (Loki 로그 저장용 S3 호환 백엔드) | `quay.io/minio/minio:latest` |
| Kueue Operator | 미설치 (시나리오 11에서 사용 예정, 계획 단계) |

| 워크로드 | 내용 |
|---|---|
| vLLM 서빙 모델 (시나리오 8·9) | `Qwen/Qwen2.5-0.5B-Instruct` |
| vLLM 런타임 이미지 | `registry.redhat.io/rhoai/odh-vllm-cuda-rhel9` |
| GPU 인스턴스 (AWS, us-east-1) | g4dn.xlarge(NVIDIA T4), g5.2xlarge(NVIDIA A10G), g6.2xlarge(NVIDIA L4) |

**모든 시나리오의 공통 기반 (사전 설치)**:
- **NVIDIA**: Node Feature Discovery(NFD) Operator + NVIDIA GPU Operator(Certified)를
  설치하면 `ClusterPolicy`가 자동 생성되어, driver/device-plugin/container-toolkit/
  DCGM Exporter daemonset을 전부 관리한다. GPU 노드에는 `nvidia.com/gpu:NoSchedule`
  taint가 자동으로 붙어, GPU를 명시적으로 요청/tolerate하는 워크로드만 스케줄된다.
- **OpenShift**: GPU 관측용으로 OpenShift 기본 User Workload Monitoring이 아니라
  **독립적인 Prometheus + Alertmanager + Grafana Operator** 스택을 별도로 둔다
  (이유는 `harness/README.md`의 "GPU monitoring / demo control-plane" 참고).

---

## 시나리오 1 — 워크노드 오토스케일링

**목적**: GPU 수요가 현재 용량을 넘으면, 인프라가 사람 개입 없이 노드를
자동으로 늘린다는 것을 증명한다.

**구성**: `training-job-1`, `training-job-2` 두 pod를 같은 GPU 플레이버
(g5.2xlarge, 1노드/1GPU)에 고정 배포 → 하나는 뜨고 하나는 `Pending` →
`MachineAutoscaler`(min=1, max=2)가 이를 감지해 노드를 1→2로 확장 → 새
노드 조인 시 Pending이던 pod도 자동 스케줄.

**필수 환경 설정**:
```yaml
# ClusterAutoscaler (클러스터 전역 싱글톤, 먼저 필요)
apiVersion: autoscaling.openshift.io/v1
kind: ClusterAutoscaler
metadata:
  name: default
spec:
  resourceLimits:
    maxNodesTotal: 20
  scaleDown:
    enabled: true
    delayAfterAdd: 10m
    delayAfterDelete: 5m
    delayAfterFailure: 3m
    unneededTime: 10m
---
# MachineAutoscaler (GPU MachineSet 하나당 1개)
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: gpu-g5-2xlarge-us-east-1a
  namespace: openshift-machine-api
spec:
  minReplicas: 1
  maxReplicas: 2
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: <cluster>-gpu-g5-2xlarge-us-east-1a
```

**장점/단점**:
- 장점: 사람 개입 없이 완전 자동으로 처리되며, 새 EC2 인스턴스가 실제로
  추가되는 것까지 확인할 수 있다
- 단점: 새 인스턴스 프로비저닝 때문에 전체 과정이 ~10분 소요된다.
  워크로드를 정리하지 않으면 늘어난 노드가 그대로 유지되어, 이후 같은
  시나리오를 재실행해도 자원 부족 상황이 재현되지 않는다

**테스트 결과**:
| 단계 | 소요시간 |
|---|---|
| MachineSet replica 1→2 반영 | ~30초 |
| 새 EC2 인스턴스 Ready | ~4분 |
| GPU 드라이버/디바이스 인식 + pod 스케줄 | ~4분 |
| 컨테이너 이미지 pull + 시작 | ~2분 |
| **합계** | **~10분** |

**시나리오 시사점**: GPU 수요 증가에 인프라팀이 수동으로 대응할 필요가
없다 — MachineAutoscaler가 Pending 상태를 감지해 노드 증설까지 자동으로
처리한다. 인프라 대응 자동화의 가장 기본적인 형태다.

---

## 시나리오 2 — GPU 과열 알람

**목적**: GPU가 과열되면 대시보드에서 실시간으로 확인되고, Slack으로
자동 알림이 감을 증명한다.

**구성**: `gpu-burn` pod가 GPU를 100% 사용하도록 무한 부하 → Grafana
Tier1 "Real-time GPU Temperature by Node" 패널에서 온도 상승 실시간
확인 → 70℃ 이상 2분 지속 시 `GPUHighTemperature` 알람 firing → 독립
Prometheus + Alertmanager가 Slack 채널로 전송.

**필수 환경 설정**:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-scenario1-alerts-standalone
  labels:
    role: gpu-alert-rules
spec:
  groups:
  - name: gpu-overheat-and-faults
    rules:
    - alert: GPUHighTemperature
      expr: DCGM_FI_DEV_GPU_TEMP >= 70
      for: 2m
      labels:
        severity: critical
    - alert: GPUXidError
      expr: DCGM_FI_DEV_XID_ERRORS != 0
      for: 0m
      labels:
        severity: critical
```
```yaml
# Alertmanager 설정 (Secret alertmanager.yaml)
route:
  receiver: slack-gpu-alerts
  group_by: ["alertname", "Hostname"]
  group_wait: 10s
  group_interval: 5m
  repeat_interval: 1h
receivers:
- name: slack-gpu-alerts
  slack_configs:
  - api_url: "https://hooks.slack.com/services/..."
    channel: "#alert-demo"
    send_resolved: true
```
DCGM 메트릭(`DCGM_FI_DEV_GPU_TEMP`) 자체는 NVIDIA GPU Operator의
`ClusterPolicy.spec.dcgmExporter`(기본 활성화)가 노출 — 별도 설정 불필요.

**장점/단점**:
- 장점: 관측성(Grafana)과 알림(Alertmanager→Slack) 파이프라인이 감지부터
  해소까지 하나로 연결되어 있고, 리소스 소모가 적어 빠르게 확인할 수 있다
- 단점: 이 클러스터의 GPU(g5/g6)는 실측상 85℃까지 오르지 않아 임계값을
  70℃로 낮춰 설정했다 — 실제 운영 환경에서는 GPU 기종·냉각 조건에 맞게
  재조정이 필요하다

**테스트 결과**: 부하 시작 후 수십 초~수 분 내 70℃ 도달(실측 최대
~82℃), 70℃ 도달 후 2분 지속 시 알람 발동, Slack 전송까지 수 초 이내.
pod 삭제 후 온도 하락 시 알람도 자동으로 `resolved`로 전환되고 Slack에도
resolved 메시지 전송.

**시나리오 시사점**: GPU 발열로 인한 화재 사고를 미연 방지를 위한 시나리오. 감지(Grafana)→알림(Slack)→해소(resolved)까지
자동화된 완결된 운영 루프다. 알람 임계값은 GPU/클러스터 환경에 맞게
재조정할 수 있다.

---

## 시나리오 3 — GPU Power Capping (Green AI)

**목적**: GPU 전력 상한을 낮추면 전력 소비가 즉시 줄어드는 것을 실시간
대시보드로 보여주고, "성능 손실보다 전력 절감이 큰" 조건이 실제로
존재하는지 데이터로 검증한다.

**구성**: `power-load` pod가 짧은 연산(burst) 후 대기(idle)를 반복하는
버스티 워크로드(실제 추론 서빙 패턴 흉내) → 노드에서 `nvidia-smi -pl`로
전력 상한 직접 조정 → Grafana Tier1 "Power Draw per GPU" 패널에서
두 GPU로 비교 측정.

**필수 환경 설정**:본 데모에서는 oc exec 로 직접 pod에서 nvidia 명령어를 수행했지만, initContainer에 명령어를 삽입하여 기동 시 부터 Watt를 조절 가능

```bash
# 전력 캡은 별도 CR이 없고, GPU Operator의 driver daemonset pod 안에서
# nvidia-smi를 직접 실행하는 방식이다.
oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver

oc exec -n nvidia-gpu-operator <driver-pod> -- nvidia-smi -i 0 -pl <watt>
```
```yaml
# 대상 노드 레이블 (전력 캡을 적용할 GPU 플레이버 선택 기준)
node.kubernetes.io/instance-type: g6.2xlarge   # NVIDIA L4, 40~72W
node.kubernetes.io/instance-type: g5.2xlarge   # NVIDIA A10G, 100~300W
```

**장점/단점**:
- 장점: 전력 절감과 성능 손실을 실측 데이터로 직접 비교해, GPU 기종에
  따라 결과가 달라진다는 것을 정량적으로 확인할 수 있다
- 단점: 작은 카드(L4)는 테스트 범위 안에서 성능 손실이 전력 절감보다
  큰 구간을 벗어나지 못했다

**테스트 결과**:
| GPU | 최적 캡 | 전력 절감 | 성능 손실 | 손실/절감 비율 |
|---|---|---|---|---|
| L4 (g6.2xlarge) | 60W | -6.4% | -6.5% | 1.02x (손익분기점 수준) |
| A10G (g5.2xlarge) | 120W | -26~27% | -23~24% | **0.86~0.90x (평균 0.88x, 유리)** |

![전력 절감 vs 성능 손실 산점도: 손익분기선 기준 L4(포화/버스티)는 위쪽 손해 구간, A10G 120W는 아래쪽 이득 구간](image/scenario3-result.png)

**시나리오 시사점**: 
1) 전력 캡이 항상 이득인 것은 아니다 — **카드의 절대
전력 예산이 클수록, 워크로드에 유휴 구간이 있을수록** 유리해진다. A10G급
이상의 카드에서 버스티한(추론형) 워크로드를 돌릴 때 효과가 가장 뚜렷하고,
L4 같은 저전력 카드는 이 조건을 충족하지 못하면 이득 구간이 나타나지
않는다.
2) 인스턴스가 많거나 발열을 낮추기 위한 냉각 비용이 더 높다면 출력을 낮추고 발열 관리를 할 필요성 존재
---

## 시나리오 4 — GPU 노드 장애 격리 및 자동 재배치

**목적**: GPU 노드에 장애가 생기면, 인프라팀이 cordon & drain하는 것만으로
사람이 워크로드를 직접 옮기지 않아도 자동으로 다른 정상 노드에
재배치됨.

**구성**: `fault-workload`를 Deployment(replica=1)로 배포(특정 GPU
플레이버에 고정하지 않음) → 해당 노드를 cordon+drain → 컨트롤러가 pod를
자동 재생성해 다른 GPU 노드로 재배치.

**필수 환경 설정**:
```yaml
# GPU MachineSet 생성 시 반드시 걸어두는 taint, tolerate 안 하는 pod는 새로 여기 스케줄되지 못한다
# GPU가 필요 없는 일반 워크로드가 GPU 노드에 들어가 Resource를 잠식하는 걸 막기 위해서 필요
spec:
  template:
    spec:
      taints:
      - key: nvidia.com/gpu
        value: ""
        effect: NoSchedule
```
- **Taint(노드에 건다)**: "이 노드는 기본적으로 막혀 있다"는 표시.
  key/value/effect 세 부분으로 구성되며(`nvidia.com/gpu` / `""` /
  `NoSchedule`), **아무 toleration도 없는 pod는 이 노드에 스케줄될 수
  없다.**
- **Toleration(pod에 건다)**: "나는 이 taint를 견딜 수 있다"는 예외
  신청. `fault-workload`는 아래 toleration을 갖고 있어서 GPU 노드에도
  스케줄 후보가 될 수 있다:
  ```yaml
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  ```
- **오해하기 쉬운 점**: toleration은 "이 노드에 우선 배치해달라"는 뜻이
  **아니다** — 그냥 taint 때문에 막히지 않게 해줄 뿐, 실제로 어느 노드에
  갈지는 여전히 스케줄러가 리소스 요청량 등을 보고 정상적으로 결정한다.
  즉 **taint+toleration은 "밀어내기(반대로는 안 막음)"** 메커니즘이고,
  특정 노드를 반드시 골라 배치하고 싶다면 `nodeSelector`/`affinity`를
  별도로 써야 한다.
- 결과적으로: toleration이 없는 일반 워크로드는 GPU 노드에 얼씬도 못 하고,
  `fault-workload`처럼 toleration이 있는 pod만 GPU 노드를 후보로 고려할 수
  있다 — 이 시나리오가 "GPU 노드끼리만 재배치"되는 게 보장되는 이유.

```bash
oc adm cordon <node>
oc adm drain <node> --ignore-daemonsets --delete-emptydir-data --force
```
- **cordon**: 노드를 `SchedulingDisabled` 상태로 표시 — **새 pod가 그
  노드에 스케줄되는 것만 막는다.** 이미 떠 있는 pod는 그대로 유지되고,
  아무것도 강제로 쫓아내지 않는다(taint의 `NoSchedule`과 비슷한 성격이지만,
  cordon은 노드 전체에 적용되는 별개의 메커니즘).
- **drain**: cordon된 노드에서 **실행 중인 pod를 실제로 축출**한다.
  DaemonSet이 만든 pod는 `--ignore-daemonsets`로 건드리지 않고, 나머지는
  Eviction API로 정상 종료 후 제거한다 — `fault-workload`도 이때 쫓겨난다.
  Deployment 컨트롤러가 즉시 대체 pod를 만들지만, 방금 cordon된 이
  노드에는(스케줄링이 막혀 있으므로) 재스케줄될 수 없어 다른 정상 GPU
  노드로 넘어간다.
- 즉 **cordon이 "이 노드는 더 이상 후보가 아니다"를 선언**하고, **drain이
  "그러니 여기 있던 것들은 나가라"를 실행**하는 두 단계로 나뉘어 있다 —
  실제 인프라팀이 장애 노드를 다룰 때 쓰는 표준 절차 그대로다.

**장점/단점**:
- 장점: 새 인스턴스 프로비저닝이 필요 없어 가장 빠르게(~1분) 결과가
  나오며, 실제 장애 대응 워크플로우와 동일한 절차를 사용한다
- 단점: 진짜 하드웨어 장애(XID 에러 등)를 안전하게 강제 유발할 방법이
  없어, 인프라팀의 대응 조치(cordon & drain)부터 시작하는 시뮬레이션이다

**테스트 결과**: cordon → drain → Deployment 컨트롤러가 즉시 새 pod
생성 → 다른 GPU 노드에 자동 스케줄 → 약 1분 이내 `Running` 전환.
Grafana "GPU Utilization by Node" 패널에서 원래 노드는 0%로, 새 노드는
100%로 전환되는 것을 교차 확인.

**시나리오 시사점**: Deployment(컨트롤러 기반)로 배포해야 자동 복구됨으로, 재배치를 받아줄 여유 있는 GPU 노드가 최소 1대 있어야 한다.

---

## 시나리오 5 — 비효율 코드 탐지 (Bad Code Penalty)

**목적**: 똑같은 학습 코드라도 `DataLoader`의 `num_workers` 설정 하나
차이로 비싼 GPU를 얼마나 놀리는지 실측 그래프로 증명한다.

**구성**: 동일한 학습 코드를 세 가지 설정으로 순차 실행 — `bad-code`
(`num_workers=0`), `efficient`(`num_workers=4`), `more-efficient`
(`num_workers=4` + 연산 시간 증가). 앱이 직접 노출하는
`train_steps_total` Prometheus 카운터로 스크레이프 타이밍에 흔들리지
않는 정확한 처리량을 측정하고, Grafana Tier2에서 GPU 사용률/메모리/
처리량을 pod별로 비교.

**필수 환경 설정**:
```yaml
# ClusterPolicy.spec.devicePlugin -- time-slicing 미적용(기본값) 상태를 유지
# config 필드가 아예 없어야 물리 GPU 1장 = nvidia.com/gpu 1개로만 스케줄됨
spec:
  devicePlugin:
    enabled: true
    # config: (참조 없음 -- time-slicing 비활성 상태)
```

```promql
# train_steps_total은 학습 스크립트가 :9091/metrics로 직접 노출하는
# 앱 레벨 카운터. rate()로 감싸서 스크레이프 타이밍(30초 간격)에
# 흔들리지 않는 정확한 초당 처리량을 얻는다.
rate(train_steps_total{namespace="$namespace"}[1m])
```
이 메트릭은 독립 Prometheus 에서만 수집되므로,
Grafana 패널의 datasource를 플랫폼 Thanos Querier(`${DS_THANOS}`)가 아니라
`{"type": "prometheus", "uid": "gpu-alert-prom"}`로 명시해야 한다.

**장점/단점**:
- 장점: 인위적인 `sleep`이 아니라 실제 PyTorch `DataLoader` 메커니즘으로
  재현했고, 앱 레벨 카운터 지표라 스크레이프 타이밍에 따른 그래프 노이즈가
  없다
- 단점: GPU 사용률(GPU_UTIL) 그래프만으로는 두 워크로드 모두 피크가
  100%로 찍혀 차이가 미묘하게 보일 수 있다 — 처리량 지표를 함께 봐야
  차이가 명확해진다

**테스트 결과**:

| 워크로드 | `num_workers` | matmul 반복 | 처리량(steps/sec) | GPU_UTIL 패턴 | GPU 메모리 |
|---|---|---|---|---|---|
| `bad-code-workload` | 0 | ×10 | 0.13~0.15 | 대부분 0%, 짧은 스파이크 1회(~90%) | ~380MB |
| `efficient-workload` | 4 | ×10 | 0.5~0.65 | 0%↔100% 반복(스파이크 2회) | ~430MB |
| `more-efficient-workload` | 4 | ×60 | 0.35~0.55 | 뜨고 나서 끊김 없이 계속 100% | ~450MB |

**용어 정의**:
- **matmul (행렬곱, Matrix Multiplication)**: 두 행렬을 곱하는 연산
  (`torch.matmul(w, w)`, 4096×4096 텐서). 실제 모델 학습에서 GPU가 하는
  핵심 계산을 대표하는 연산이며, 배치 하나당 이 연산을 몇 번 반복하는지가
  GPU가 얼마나 오래 "계산 중"인 상태로 있는지를 결정한다 — 반복 횟수가
  많을수록 GPU 연산 시간이 길어진다.
- **`num_workers`**: PyTorch `DataLoader`가 다음 배치를 준비할 때 띄우는
  **별도 워커 프로세스 개수**. `0`이면 메인 프로세스가 배치를 하나씩
  순차적으로 직접 준비하고, 그동안 GPU는 완전히 대기 상태다. `4`처럼
  0보다 크면 별도 워커들이 GPU가 현재 배치를 계산하는 **동안** 다음
  배치를 미리 준비해두어, GPU가 노는 시간을 줄인다.

동일 시간(100초) 동안 `bad-code`는 10 step, `efficient`는 50 step을
처리했다 — `num_workers` 설정 하나 차이로 **5배**. GPU 메모리 사용량은
세 워크로드 모두 비슷한 범위(380~450MB)인데, 모델 크기와 배치 크기가
동일하기 때문이다 — 메모리는 `num_workers`/matmul 반복 횟수와 무관하다.

![Scenario 5 결과: Tier2 대시보드에서 세 워크로드의 GPU 사용률, 메모리, 처리량 비교](image/scenario5-result.png)

**시나리오 시사점**: "GPU 사용률이 낮다"는 문제의 가장 흔한 원인이
데이터 파이프라인 병목이라는 것을 정량적으로 증명한다. GPU_UTIL 같은
인프라 지표보다 **처리량(steps/sec)** 같은 애플리케이션 레벨 지표가
훨씬 신뢰. 이 시나리오에서
적발된 팀에 대한 후속 조치는 시나리오 6으로 이어진다.

**확장 활용**:
1. **GPU ROI 진단**: GPU_UTIL은 높은데 실제 결과가 늦게 나오는 경우,
   인프라 지표만으로는 원인을 알 수 없다 — 이 패턴(앱 자체 카운터)을
   붙이면 실제 처리량을 직접 확인할 수 있다.
2. **운영 배포 전 부하테스트**: 프로덕션 반영 전에 같은 방식의 카운터를
   붙여 실제 처리량을 측정하고, 기준을 통과하면 코드에서 제거한다.

**코드 — 학습 루프에 카운터 추가**:
```python
# 이 harness가 실제로 쓴 방식 (pip 설치 없이, stdlib만으로)
import threading, http.server

class _MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"train_steps_total {step}\n".encode())

threading.Thread(
    target=lambda: http.server.HTTPServer(("0.0.0.0", 9091), _MetricsHandler).serve_forever(),
    daemon=True,
).start()

for batch in loader:
    ...
    step += 1
```
```python
# 일반 프로덕션 환경이라면 표준 라이브러리 사용 (pip install prometheus-client)
from prometheus_client import Counter, start_http_server

train_steps = Counter("train_steps_total", "Training steps completed")
start_http_server(9091)

for batch in loader:
    ...
    train_steps.inc()
```

---

## 시나리오 6 — PriorityClass 하향 및 Preemption 실효성 증명

**목적**: 시나리오 5에서 적발된 비효율 코드 팀에게 인프라팀이
PriorityClass를 Low로 낮췄다고 할 때, 이 조치가 자원 부족 시 실제로
강제 집행되는지 증명한다.

**구성**: `low-priority-workload`(낮은 PriorityClass)가 유일한 GPU를
선점 → `high-priority-workload`(기본 우선순위) 배포 시 Kubernetes가
자동으로 low-priority pod를 축출(Preemption)하고 그 자리를 내어줌.
오토스케일러가 새 노드를 추가해 Preemption을 우회하지 못하도록,
`MachineAutoscaler`의 `max`를 현재 replica 수로 고정해 "자리가 없는"
상태를 보장한다(이미 노드가 1대로 고정된 GPU 플레이버를 쓰면 이 단계
자체가 필요 없음).

**필수 환경 설정**:
```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority-team
value: -1000000
globalDefault: false
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority-team
value: 1000
globalDefault: false
```
`low-priority-workload`는 `priorityClassName: low-priority-team`을 명시하고,
`high-priority-workload`는 위 `high-priority-team`을 명시하거나 — 혹은
아무 `priorityClassName`도 지정하지 않아 Kubernetes 기본값(0)을 그대로
쓸 수도 있다(0 > -1000000이라 어느 쪽이든 결과는 동일).
```yaml
# 기존 MachineAutoscaler(시나리오 1)의 max를 현재 replica 수로 고정
# -- 오토스케일러가 새 노드를 추가해 Preemption을 우회하지 못하게 차단
spec:
  minReplicas: 1
  maxReplicas: 1   # 현재 replica 수와 동일하게 고정
```

**장점/단점**:
- 장점: Kubernetes 이벤트 로그에 "Preempted by pod ..."가 명시적으로
  남아, 우연한 재시작이 아니라 실제 Preemption이 일어났음을 증거로 확인할
  수 있다. 오토스케일러와의 경쟁 상태까지 제어된 구성이다
- 단점: 오토스케일 여지를 인위적으로 차단한 상태에서 진행되므로, 실제
  운영 환경보다 통제된 조건이다

**테스트 결과**: `high-priority-workload` 배포 후 **약 33~34초 만에**
Preemption 이벤트 확인 — low-priority pod는 축출되어 사라지고(`Gone`),
high-priority pod가 그 GPU에서 `Running`으로 전환.

**시나리오 시사점**: PriorityClass 하향은 단순한 정책 "선언"에 그치지
않는다 — 자원 경합이 발생하는 순간 Kubernetes가 자동으로 강제 집행하는
실질적인 거버넌스 메커니즘이다. 인프라팀의 정책적 조치가 기술적으로
뒷받침된다.
 예) 보안 Agent - priority 상향 조정, Agent Orchestration 혹은 SPOF(Single Point of Failure) 위험성 존재 Agent - priority 상향 조정

---

## 시나리오 7 — 비용 초과 대응 (Chargeback & Quota)

**목적**: 팀이 예산을 다 썼다고 판단되면, `ResourceQuota` 하나로 그
팀의 GPU 확장을 즉시 막을 수 있음을 증명한다.

**구성**: `team-workload-1`(팀의 기존 사용량)이 배포된 상태에서
`ResourceQuota`(`requests.nvidia.com/gpu: "1"`)를 현재 사용량과 동일한
값으로 적용 → `team-workload-2`(추가 GPU 요청) 시도 시 API 서버
admission 단계에서 즉시 거부.

**필수 환경 설정**:
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
spec:
  hard:
    requests.nvidia.com/gpu: "1"
```
별도 오퍼레이터 불필요 — OpenShift Project(네임스페이스)의 admission 제어
체인에서 API 서버 자체가 강제하는 표준 기능이다.

**장점/단점**:
- 장점: 스케줄링을 기다릴 필요 없이 **API 요청 즉시 거부**되는 가장
  빠르고 결정적인(deterministic) 방식 — 경쟁 상태가 발생할 여지가 없다
- 단점: Tier1의 "Estimated GPU Cost" 패널은 실제 청구 시스템과 연동된
  것이 아니라 일러스트레이션용 추정치이며, 실제 AWS 청구액과는 다를 수
  있다

**테스트 결과**: `team-workload-2` 배포 시도 시 pod 자체가 생성되지
않음(`oc get pods`에 뜨지도 않음) — `exceeded quota` 에러가 즉시
반환됨. 시나리오 4(cordon+drain, ~1분), 시나리오 6(preemption, ~34초)보다
훨씬 빠르다.

**시나리오 시사점**: Quota는 요청이 들어오는 그 순간 작동하는 가장
확실하고 빠른 통제 수단이다. 스케줄링/Preemption 기반의 시나리오
4·6이 "사후 조치"라면, 이 시나리오는 "예방"에 해당한다.

---

## 시나리오 8 — KServe + vLLM 부하 기반 오토스케일링 (KEDA)

**목적**: KServe로 서빙하는 vLLM 모델이 실제 요청 부하(큐 depth)에 따라
replica를 자동으로 늘리고 줄이는 것을 Red Hat의 공식 권장 패턴으로
증명한다.

**구성**: KEDA `ScaledObject`(`minReplicaCount: 1`, `maxReplicaCount: 2`)가
vLLM 자신이 노출하는 `vllm:num_requests_waiting`(요청 큐 depth)을
트리거로 사용 — GPU 사용률이 아니다. GPU time-slicing으로 물리 GPU
1장에 2 replica를 동시 운영하고, Service Mesh 없이 가벼운
RawDeployment 모드로 배포한다.

**필수 환경 설정**:
```yaml
# DataScienceCluster (RHOAI) -- Service Mesh 없이 순수 RawDeployment로 전환
spec:
  components:
    kserve:
      managementState: Managed
      defaultDeploymentMode: RawDeployment
      serving:
        managementState: Removed
```
```yaml
# OpenShift Custom Metrics Autoscaler Operator (KEDA)
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-custom-metrics-autoscaler-operator
  namespace: openshift-keda
spec:
  channel: stable
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: keda.sh/v1alpha1
kind: KedaController
metadata:
  name: keda
  namespace: openshift-keda
spec:
  watchNamespace: ""
```
```yaml
# NVIDIA GPU Operator -- time-slicing (물리 GPU 1장을 2개 스케줄 단위로)
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: nvidia-gpu-operator
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: 2
---
# ClusterPolicy.spec.devicePlugin.config
spec:
  devicePlugin:
    config:
      name: time-slicing-config
      default: "any"
```

**장점/단점**:
- 장점: Service Mesh 같은 무거운 의존성 없이 부하 기반 오토스케일 가능,
  요청 큐 depth라는 LLM 서빙에 적합한 신호를 트리거로 사용(GPU 사용률은
  순간 스파이크에 흔들려 부적합)
- 단점: `minReplicaCount: 0`(완전한 scale-to-zero)은 이 아키텍처에서
  구조적으로 불가능 — 활성 pod가 없으면 트리거 메트릭 자체가 없어서
  자동으로 못 깨어남. 진짜 0→1이 필요하면 시나리오 9(Knative) 필요

**테스트 결과**: 부하 시작 후 **약 10초 만에** 1→2 스케일업 시작, 두
replica 모두 Ready까지 약 70초. 부하 종료 후 **약 60초 만에** 2→1
스케일다운 완료. 완전히 초기화한 뒤 재배포해도 동일하게 재현됨을 확인.

![Scenario 8 결과: replica 수와 vllm:num_requests_waiting 큐 depth가 함께 스케일링되는 모습](image/scenario8-result.png)

**시나리오 시사점**: RawDeployment+KEDA는 "이미 떠 있는 상태에서 부하에
따라 탄력적으로 늘고 주는" 용도에 최적화된 가벼운 선택지다. 예) 24시간 서비스가 필요한 중요 업무,  Service
Mesh 도입 부담 없이 오토스케일이 필요한 경우에 적합하며, 진짜
wake-from-zero가 필요하다면 시나리오 9의 아키텍처가 필요하다.

---

## 시나리오 9 — KServe Serverless(Knative) + vLLM 진짜 Scale-to-Zero

**목적**: 진짜 요청 기반 0→1 자동 기동(wake-from-zero)이 실제로
되는지 증명한다 — 이것이 원래 KServe가 scale-to-zero를 하도록 설계된
방식이다.

**구성**: OpenShift Serverless + Red Hat OpenShift Service Mesh를 설치
(KServe Serverless 모드는 Service Mesh와 짝을 이루는 게 Red Hat 공식
지원 아키텍처). `InferenceService`를 `minReplicas: 0`의 Serverless
모드로 배포하고, 모델을 PVC에 사전 캐싱해 콜드스타트마다 재다운로드하지
않도록 한다. 요청이 0 replica 상태로 들어오면 Knative `Activator`가
요청을 큐에 붙잡아두고 스케일업을 트리거한 뒤, pod가 준비되면 그대로
전달한다.

**필수 환경 설정**:
```yaml
# OpenShift Serverless + Service Mesh 오퍼레이터
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-operators
spec:
  channel: stable
  source: redhat-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  source: redhat-operators
```
```yaml
# ServiceMeshControlPlane -- 이름/네임스페이스가 RHOAI에 하드코딩돼 있어
# 반드시 이 값이어야 함
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: data-science-smcp
  namespace: istio-system
spec:
  version: v2.6
  security:
    dataPlane:
      mtls: false
    identity:
      type: ThirdParty
  gateways:
    ingress:
      enabled: true
---
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
  - knative-serving
  - gpu-kserve-scenario-9
```
```yaml
# DataScienceCluster (RHOAI) -- Knative 기반 Serverless 경로 활성화
spec:
  components:
    kserve:
      serving:
        managementState: Managed
```

**장점/단점**:
- 장점:  0 replica에서 요청이 오면 자동으로 깨어남 — 유휴 시간
  GPU 비용을 완전히 0으로 만들 수 있음, 요청 자체가 실패하지 않고
  큐에서 대기하다 처리됨
- 단점: Service Mesh라는 무거운 의존성이 필요(시나리오 8과의 핵심
  트레이드오프), 콜드스타트 자체는 여전히 존재(모델을 GPU에 로드하는
  시간)

**테스트 결과**:

| 구간 | 소요 시간 | 비고 |
|---|---|---|
| 모델 기동(콜드스타트, pod 생성 → Ready) — 모델 재다운로드(`hf://`) | 70~110초 | 매 콜드스타트마다 Hugging Face Hub에서 재다운로드 |
| 모델 기동(콜드스타트, pod 생성 → Ready) — PVC 사전 캐싱(`pvc://`) | **~49초** | 최적화 후 (네트워크 다운로드 없이 PVC 마운트만) |
| Scale-up (0→1, 콜드스타트를 유발한 첫 요청의 실제 응답 수신까지) | **50.47초** | PVC 캐싱 적용 후, 재시도 없이 성공 |
| Scale-down (요청 종료 → 0 replica) | 약 60~90초 | Knative 기본 설정값(안정화 윈도우 + scale-to-zero grace period, `knative-serving`의 `config-autoscaler` ConfigMap) 기준 — 초 단위로 직접 측정한 값은 아님 |

콜드스타트가 70~110초였을 때는 서빙 경로 자체의 타임아웃(~60초)보다
길어서, 요청이 응답을 못 받고 끊기는 경우가 많았다. PVC 캐싱으로
49초까지 줄이자 그 타임아웃 벽 아래로 들어와, 콜드스타트를 유발한 첫
요청도 재시도 없이 성공하게 됐다.

**시나리오 시사점**: Service Mesh를 도입하는 대신 유휴 시간 GPU 비용을
0원으로 만드는 트레이드오프다 — 트래픽이 간헐적인 워크로드(야간 배치,
저빈도 추론 등)에 적합한 아키텍처다. PVC 사전 캐싱은 콜드스타트를 서빙
경로의 타임아웃 안으로 줄이는 핵심 최적화다.

---

## 시나리오 10 — Scale-to-Zero 상태의 모니터링 (KEDA vs Knative)

**목적**: 0 replica로 idle한 상태에서도 "지금 무슨 일이 있는지"를 계속
관측할 수 있어야 한다는 실전 요구를, 시나리오 8(KEDA)과 시나리오
9(Knative) 두 아키텍처에서 나란히 검증한다.

**구성**: Grafana Tier1에 두 시나리오의 replica 수 시계열 패널을 나란히
배치하고, 실제 요청을 양쪽에 보내 콜드스타트 결과를 비교하는 스크립트를
실행한다. 별도로 OpenShift Logging(Loki)을 구축해 pod가 삭제된 뒤에도
로그가 조회되는지 검증한다.

**필수 환경 설정**:
```yaml
# OpenShift Logging -- Loki Operator + Cluster Logging Operator
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.6
  source: redhat-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-6.6
  source: redhat-operators
```
```yaml
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: 1x.demo
  storage:
    schemas:
    - version: v13
      effectiveDate: "2024-01-01"
    secret:
      name: logging-loki-s3
      type: s3
  tenants:
    mode: openshift-logging
---
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  serviceAccount:
    name: logging-collector
  collector:
    tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
```

**장점/단점**:
- 장점: "pod가 없어도 이전에 무슨 일이 있었는지 알 수 있어야 한다"는
  운영 요구를 메트릭(Grafana)과 로그(Loki) 두 축에서 모두 증명
- 단점: Knative 자체 control-plane 메트릭(activator/autoscaler)은
  아직 노출되지 않아 kube-state-metrics 기반 지표로 우회 — 완전한
  Knative 네이티브 관측성은 아님

**테스트 결과**: 0 replica 상태에서 요청을 보내면 KEDA(시나리오 8)는
DNS 조회 단계에서부터 즉시 실패, Knative(시나리오 9)는 51초 뒤 실제
응답 성공(재시도 불필요) — 두 아키텍처의 차이가 그대로 드러남. 로깅
측면에서는 pod 삭제 후 `oc logs`는 `NotFound`지만, 동일한 로그가
Loki에는 여전히 남아있음을 확인.

**시나리오 시사점**: "GPU 비용 0원"과 "운영 가시성 확보"는 별개의
문제다 — scale-to-zero 아키텍처를 도입하더라도, 로깅/모니터링
파이프라인은 pod의 생명주기와 독립적으로 설계되어야 실전에서 쓸 수
있다.

---

## 시나리오 11 — Kueue + Dynamic Resource Allocation (DRA)

> 상태: 설계 확정, harness 구현 예정 (아직 실측 결과 없음)

**목적**: 지금까지의 시나리오는 모두 Kubernetes 기본 스케줄러와
`nvidia.com/gpu: N` 정수 카운팅에 의존하는데, 진짜 멀티테넌트 GPUaaS
플랫폼이 갖춰야 할 **큐잉/쿼터/공정분배(Kueue)**와 **구조화된 GPU
할당(DRA)** 계층을 보여준다.

**구성(계획)**: Kueue의 `ClusterQueue`/`LocalQueue`로 팀별 GPU 쿼터
구성 → 쿼터를 초과하는 Job은 스케줄러에 넘어가기 전 Kueue admission
단계에서 대기열에 머무름 → 앞선 Job이 끝나 쿼터가 비면 공정분배/우선순위
규칙에 따라 자동 admit → 실제 GPU 할당은 `ResourceClaim`(DRA)이라는
구조화된 API로 이뤄짐.

**필수 환경 설정(계획, 미구현)**:
```yaml
# Red Hat build of Kueue 오퍼레이터
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kueue-operator
  namespace: openshift-operators
spec:
  channel: stable
  source: redhat-operators
```
```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: gpu-flavor
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: gpu-cluster-queue
spec:
  resourceGroups:
  - coveredResources: ["nvidia.com/gpu"]
    flavors:
    - name: gpu-flavor
      resources:
      - name: "nvidia.com/gpu"
        nominalQuota: 2
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: team-a-queue
spec:
  clusterQueue: gpu-cluster-queue
```

**장점/단점**:
- 장점(예상): 단순 정수 카운팅을 넘어선 표준화된 최신 GPU 할당
  방식(Kubernetes 최신 표준), 팀별 공정 분배까지 스케줄러 이전
  단계에서 관리 가능
- 단점: 이 클러스터의 GPU(A10G, L4, T4)는 하드웨어 자체가 MIG(GPU
  쪼개기)를 지원하지 않아, "GPU 하나를 여러 팀이 나눠 쓰는" 데모는 이
  시나리오 범위에 포함되지 않음 — 온전한 GPU 단위 요청이 Kueue/DRA를
  거치는 것에 집중

**테스트 결과**: 아직 없음 — 다음 단계에서 harness에 구현 후 실측
예정.

**시나리오 시사점**: 지금까지의 시나리오 1~10이 "기본 스케줄러 + 정수
카운팅"으로 가능한 범위를 다뤘다면, 이 시나리오는 프로덕션급 멀티테넌트
GPUaaS 플랫폼으로 가기 위한 다음 단계를 제시한다.
