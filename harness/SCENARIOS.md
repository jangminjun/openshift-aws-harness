# GPU 데모 시나리오

`myocp` 클러스터(OpenShift + OpenShift AI + GPU Operator + 모니터링 스택)가 이미
구축되어 있다는 전제 하에, 고객 데모용으로 준비된 시나리오들을 순서대로 정리한
문서입니다. 번호는 **발표 순서** 기준이며, `openshift-monitoring` 문서 자체의
시나리오 번호(1: 과열/장애, 2: GPU 오남용, 3: 비효율 코드, 4: Chargeback)와는
다릅니다 — 이 데모의 "시나리오 2(알람)"가 문서상으로는 "시나리오 1"에 해당하고,
"시나리오 3(Power Capping)"은 문서의 별도 섹션인 "Green AI"에 해당합니다.

실행은 두 가지 방법 모두 가능합니다:
- 로컬에서 `./harness.sh <command>` (harness 체크아웃 + AWS 프로필 필요)
- bastion에 SSH 접속 후 `~/scenario*.sh` 직접 실행 (가장 빠름, 데모 중 추천)

```bash
ssh -i ~/.ssh/myocp-bastion ec2-user@<bastion-public-ip>
```

---

## 시나리오 1 — 워크노드 오토스케일링

**보여주는 것**: GPU 수요가 현재 용량을 넘으면, 인프라가 사람 개입 없이 노드를
자동으로 늘린다.

**구성**:
- `training-job-1`, `training-job-2` 두 개의 pod를 **같은 GPU 플레이버**
  (`g5.2xlarge`, NVIDIA A10G)에 고정해서 배포
- 각 pod는 `nvidia.com/gpu: 1` 요청 — 그런데 g5 MachineSet은 현재 1노드/1GPU뿐
- 하나는 뜨고, 하나는 `Pending` (`Insufficient nvidia.com/gpu`)
- `MachineAutoscaler`(min=1, max=2)가 이를 감지해서 g5 MachineSet을 1→2로 확장
- 새 노드가 조인하면 Pending이던 pod도 스케줄됨

**실행**:
```bash
# bastion에서
~/scenario1-autoscale-start.sh

# 또는 로컬에서
./harness.sh scenario1-autoscale-demo
```

**지켜볼 것**:
```bash
oc get pods -n gpu-autoscale-scenario-1 -o wide -w
oc get machineset -n openshift-machine-api | grep g5-2xlarge
```

**타이밍** (실측):
| 단계 | 소요시간 |
|---|---|
| MachineSet replica 1→2 반영 | ~30초 |
| 새 EC2 인스턴스 Ready | ~4분 |
| GPU 드라이버/디바이스 인식 + pod 스케줄 | ~4분 |
| 컨테이너 이미지 pull + 시작 | ~2분 |
| **합계** | **~10분** |

10분은 실시간으로 지켜보기엔 길어서, "제출 → Pending 확인 → (다른 얘기 하는 동안 대기) → 노드 늘어난 거 확인" 식으로 진행 추천.

**정리 (데모 후 반드시 실행)**:
```bash
~/scenario1-autoscale-stop.sh
# 또는: ./harness.sh scenario1-autoscale-demo-stop
```
pod만 삭제되며, 늘어난 노드는 `ClusterAutoscaler`가 유휴 10분(`unneededTime`) 후
자동으로 축소합니다. **바로 다음 데모를 다시 돌릴 계획이라면, 노드가 아직 2대인
동안 재실행하면 Pending이 발생하지 않아 시연이 안 됩니다** — 아래로 강제 리셋:
```bash
oc scale machineset myocp-z4828-gpu-g5-2xlarge-us-east-1a -n openshift-machine-api --replicas=1
```

---

## 시나리오 2 — GPU 과열 알람

**보여주는 것**: GPU가 과열되면 대시보드에서 실시간으로 보이고, Slack으로 자동
알림이 간다.

**구성**:
- `gpu-burn` pod가 PyTorch 8192×8192 행렬곱을 무한 반복하며 GPU를 100% 사용
- Grafana Tier1 대시보드의 "Real-time GPU Temperature by Node" 패널에서 온도
  상승이 실시간으로 보임
- 온도가 **70℃**(`GPU_TEMP_THRESHOLD_C`) 이상으로 2분 지속되면 `GPUHighTemperature`
  알람이 `firing`으로 전환
- 독립 Prometheus + Alertmanager(가 Slack `#alarm-gpu-monitoring` 채널로 전송

**실행**:
```bash
# bastion에서
~/scenario2-alert-start.sh

# 또는 로컬에서
./harness.sh scenario2-alert-demo
```

**지켜볼 것**:
- Grafana: https://gpu-grafana-route-gpu-monitoring.apps.myocp.sandbox4099.opentlc.com
  (`admin` / `redhat`) → Dashboards → **GPU Control - Tier 1 (Infra Global View)**
- Slack `#alarm-gpu-monitoring` 채널

**타이밍**: GPU는 부하 시작 후 수십 초~수 분 내 70℃ 도달 (실측 최대 ~82℃,
g5/g6 인스턴스는 절대 85℃까지 안 올라감 — 그래서 임계값을 70℃로 낮춰둠).
70℃ 도달 후 **2분 지속**되면 알람 발동 → Slack 전송까지 수 초 이내.

**정리**:
```bash
~/scenario2-alert-stop.sh
# 또는: ./harness.sh scenario2-alert-demo-stop
```
pod 삭제 후 온도가 내려가면 알람은 자동으로 `resolved`로 전환되고 Slack에도
resolved 메시지가 갑니다.

---

## 시나리오 3 — GPU Power Capping (Green AI)

> **상태: 스크립트만 작성됨, 캡핑 적용 후 그래프 하락까지는 아직 실측 검증 전.**
> 다음 세션에서 `scenario3-powercap-apply.sh`부터 이어서 확인할 것.

**보여주는 것**: GPU 전력 상한을 낮추면, 성능 손실은 적은데 전력 소비는 크게
줄어드는 걸 대시보드에서 실시간으로 보여준다 (원리는 위 "Green AI" 절 참고).

**구성**:
- `power-load` pod가 PyTorch 행렬곱을 무한 반복하며 GPU를 100% 사용 (g6.2xlarge,
  NVIDIA L4 — 기본/최대 전력 한도 72W, 최소 40W로 실측 확인됨)
- 워크로드가 뜬 노드의 `nvidia-driver-daemonset` pod 안에서 `nvidia-smi -pl`로
  전력 상한을 조정
- Grafana Tier1 "Power Draw per GPU" 패널에서 즉시 하락 확인 가능 (다음 스크레이프
  주기 ~30초 이내)

**실행** (bastion에서):
```bash
~/scenario3-powercap-start.sh              # power-load pod 배포, 72W 풀로드까지 대기
~/scenario3-powercap-apply.sh 50           # 50W로 캡핑 (72W 대비 약 30% 절감)
~/scenario3-powercap-apply.sh              # 인자 없이 실행하면 기본값(72W)으로 리셋
~/scenario3-powercap-stop.sh               # pod 삭제 + 전력 한도 리셋
```

**실측된 것**: `power-load` 기동 후 30초 만에 `power.draw`가 72.00W(최대치)까지
꽉 참 — 캡핑 전 베이스라인은 확인 완료. `-pl 50` 적용 후 실제로 그래프가
떨어지는지, 성능(행렬곱 처리량)이 얼마나 줄어드는지는 **아직 실측하지 않음**.

**아직 검증/보완이 필요한 것**:
- `nvidia-smi -pl` 적용 후 실제 `power.draw` 하락폭 확인
- Grafana 패널에 반영되는 데 걸리는 시간 확인
- harness 레포(`remote/scenario3-*.sh`, `harness.sh` 커맨드)에는 아직 미반영 —
  지금은 bastion(`~/scenario3-powercap-*.sh`)에만 존재

---

## 아이디어 — GPU 장애 시나리오 (미착수)

사용자 제안: 실제 GPU 하드웨어 장애(XID 에러 등)가 발생했을 때의 대응을 보여주는
시나리오. 문서 [시나리오 1]의 "인프라팀 통제 액션"(cordon & drain, 과부하 pod
강제 종료)과 맞닿아 있음 — 앞서 논의했던 "알람 발동 시 pod kill" 아이디어와도
연결 지점이 있다. 다음 세션에서 설계 이어갈 것. 후보 방향:
- XID 에러를 인위적으로 유발하는 방법 확보 (실제 하드웨어 결함을 소프트웨어로
  재현하기 까다로움 — nvidia-smi로 강제 유발 가능한지 확인 필요)
- 또는 노드를 강제로 `NotReady`로 만들어서 "장애 노드 격리" 흐름만 보여주는 방식

---

## 미구현 시나리오 (참고용, `openshift-monitoring` 문서 원본 번호 기준)

아래는 아직 harness에 자동화되어 있지 않은 시나리오들입니다. 감지 조건과
인프라팀 조치안은 문서에 정의되어 있으나, 실제 구현(PrometheusRule, 자동 통제
액션 등)은 없는 상태입니다.

### [문서 시나리오 3] 비효율 코드 지적 및 스케줄링 제한 (Bad Code Penalty)

- **상황**: 프로젝트팀 코드 미숙으로 Data Loader 병목 발생 — GPU가 주기적으로
  놀거나, HBM 메모리만 잡아놓고 실제 연산은 안 함
- **감지 조건**: GPU Memory 이용률 90%↑ 인데 연산 이용률(`DCGM_FI_DEV_GPU_UTIL`)이
  주기적으로 0%로 떨어지는 패턴
- **인프라팀 조치안**: "인프라 자원 효율성 저해" 사유로 코드 개선 요청서 공식
  발행 + 코드 개선 전까지 해당 팀 PriorityClass를 Low로 하향 (자원 부족 시
  즉시 Preemption 대상)
- **현재 가시성만 있음**: Tier1 대시보드 "GPU Compute vs Memory Utilization
  (Cluster Avg)" 패널, Tier2 대시보드 "Stall Pattern: High Memory, Low Compute"
  패널

### [문서 시나리오 4] 프로젝트별 비용 초과(Chargeback) 및 Quota 통제

- **상황**: 특정 팀이 할당된 GPU-Hour 예산을 과다 소진해서 전사 인프라 예산
  오버런 위험
- **감지 조건**: (할당 GPU 수량) × (가동시간) × (인스턴스 단가) 누적이 중간
  점검일 기준 목표 예산의 70% 초과
- **인프라팀 조치안**: ResourceQuota를 조율해서 해당 팀의 동시 실행 가능
  GPU 개수 즉시 제한 + 야간 시간대/남는 Spot 인스턴스에서만 작업이 돌도록
  Node affinity 정책 강제 변경
- **현재 가시성만 있음**: Tier1 대시보드 "GPUs Allocated" stat, Tier2 대시보드
  "My Project GPU Quota (used / hard)" bargauge

### Green AI — RHCOS 기반 GPU 전력 절감

RHCOS(Red Hat Enterprise Linux CoreOS)의 불변성(Immutability)을 활용해
선언적으로 노드/GPU 전력을 통제하는 시나리오. 3가지 방법으로 구성:

1. **Node Tuning Operator(NTO) 기반 CPU Power Profile** — RHCOS 노드의 Tuned
   Custom Resource로 유휴 상태 CPU 전력 소비 제어. 개발/테스트 노드는
   `powersave` 프로필, 운영 노드는 `performance` 프로필 유지.
2. **NVIDIA GPU Power Capping** — GPU가 최대로 끌어쓸 수 있는 전력(Watt)에
   상한선을 거는 것. `nvidia-smi -i 0 -pl <watt>` 명령(또는 이걸 노드 부팅 시
   자동 실행하는 DaemonSet)으로 설정한다.
   - **왜 되는가**: GPU는 부하가 걸리면 클럭을 최대한 올려서(부스트) 성능을
     짜내는데, 이때 소비 전력은 클럭의 세제곱에 가깝게 급증한다. 반면 성능은
     그보다 훨씬 완만하게 늘어난다 — 즉 최상위 부스트 구간은 "전력 대비
     성능 효율이 가장 나쁜 구간"이다. 여기를 깎아내면 전력은 크게, 성능은
     적게 줄어든다.
   - **구체적인 예시**: GPU 전력 한도를 400W에서 300W로 낮췄다고 하면
     - 전력 절감폭: (400 − 300) ÷ 400 = **25% 감소**
     - 이때 실측 성능 손실은 25%가 아니라 **5%에서 10% 사이**에 그친다
     - 즉 "전력은 25% 줄었는데 성능은 5~10%만 줄었다" — 전력 절감폭이 성능
       손실폭보다 훨씬 커서 이득이라는 뜻. (참고: "5~10%"의 물결표 `~`는
       "5%부터 10% 사이"라는 범위 표기다.)
3. **Bare-metal / AWS Auto-Shutdown** — 주말·야간 시간대 미사용 RHCOS 워커
   노드를 완전 종료(Scale to 0 또는 IPMI Power-Off)해서 불필요한 전력 소모
   완전 차단.

- **현재 가시성만 있음**: Tier1 대시보드 "Total GPU Power Draw", "Power Draw
  per GPU" 패널 (Power & Memory Capacity 행)

---

## 참고

- 두 시나리오는 서로 다른 네임스페이스(`gpu-autoscale-scenario-1`,
  `gpu-alert-scenario-2`)를 쓰므로 동시에 진행해도 서로 간섭하지 않습니다.
- 알람 파이프라인은 OpenShift 기본 User Workload Monitoring이 아니라
  **독립적인 Prometheus + Alertmanager**로 분리되어 있습니다 (`gpu-monitoring`
  네임스페이스). 이유와 배경은 `harness/README.md`의
  "GPU monitoring / demo control-plane" 절 참고.
- 임계값/채널 등은 재배포 시 조정 가능:
  ```bash
  GPU_TEMP_THRESHOLD_C=70 SLACK_CHANNEL='#alarm-gpu-monitoring' \
    SLACK_WEBHOOK_URL='...' ./harness.sh dcgm-alerts
  ```
