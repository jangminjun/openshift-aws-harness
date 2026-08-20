# GPU 데모 시나리오

`myocp` 클러스터(OpenShift + OpenShift AI + GPU Operator + 모니터링 스택)가 이미
구축되어 있다는 전제 하에, 고객 데모용으로 준비된 시나리오들을 순서대로 정리한
문서입니다. 번호는 **발표 순서** 기준이며, `openshift-monitoring` 문서 자체의
시나리오 번호(1: 과열/장애, 2: GPU 오남용, 3: 비효율 코드, 4: Chargeback)와는
다릅니다 — 이 데모의 "시나리오 2(알람)"와 "시나리오 4(장애 격리)"가 둘 다
문서상으로는 "시나리오 1"의 감지/조치 부분에 해당하고(하나는 감지+알림,
하나는 조치), "시나리오 3(Power Capping)"은 문서의 별도 섹션인 "Green AI",
"시나리오 5·6(비효율 코드 탐지 + PriorityClass/Preemption)"은 둘 다 문서의
"시나리오 3"의 감지/조치 부분에, "시나리오 7(Chargeback & Quota)"은 문서의
"시나리오 4"에 해당합니다.

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
- 독립 Prometheus + Alertmanager(가 Slack `#alert-demo` 채널로 전송

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
- Slack `#alert-demo` 채널

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

> **상태: harness에 완전히 반영 + 실측 검증 완료 (2026-08-13).**

**보여주는 것**: GPU 전력 상한을 낮추면 전력 소비가 즉시 줄어드는 걸
대시보드에서 실시간으로 보여준다. 처음엔 "성능 손실은 적고 전력만 크게
준다"는 일반적인 Green AI 기대(위 "Green AI" 절 참고)를 그대로 보여주려고
했는데, **100% 포화 워크로드로 실측했더니 정반대(성능 손실이 전력 절감보다
큼) 결과가 나와서**, 실제 추론(inference) 서빙처럼 짧은 연산(burst) 뒤
쉬는(idle) 구간이 있는 버스티한 패턴으로 워크로드를 다시 설계해 재측정했다.
그래도 g6.2xlarge(L4, 40~72W)에서는 손익분기점을 못 넘겼는데, **전력 예산이
훨씬 큰 g5.2xlarge(A10G, 100~300W)로 바꿔서 같은 방식으로 재측정하니 실제로
"손실 < 절감" 구간(120W, 재현 측정 평균 0.88배)을 찾아냈다** — 카드의 절대
전력 예산이 클수록 이 이론이 잘 맞는다는 걸 직접 확인한 것. 아래 네 가지
실측 데이터셋 참고 (기본값은 L4 버스티 패턴, A10G는 `DEMO_NAMESPACE`/
`POWERCAP_INSTANCE_TYPE`로 별도 배포).

**구성**:
- `power-load` pod가 8192×8192 FP32 행렬곱을 `BURST_COUNT`번(기본 3회) 연달아
  돌리고 `IDLE_SEC`초(기본 0.5초) 쉬는 걸 반복 — 실제 추론 서빙의 짧은
  요청/대기 패턴을 흉내낸 duty-cycle 워크로드다 (g6.2xlarge, NVIDIA L4 —
  기본/최대 전력 한도 72W, 최소 설정 가능 한도 40W로 실측 확인됨).
  5초 창 단위로 `throughput: N requests/sec`를 stdout에 찍어서 `oc logs`로
  실시간 성능 확인 가능 (`torch.cuda.synchronize()`로 GPU 완료 시점을 정확히
  측정 — 안 넣으면 CUDA 비동기 큐잉 때문에 처리량이 부정확하게 나옴)
- `./harness.sh scenario3-powercap-start`가 g6.2xlarge GPU MachineSet을
  (없으면) 자동으로 만들어준 다음 `power-load` pod를 배포함 — `all`로 처음부터
  설치한 클러스터에도 별도 사전 준비 없이 바로 실행 가능
- 워크로드가 뜬 노드의 `nvidia-driver-daemonset` pod 안에서 `nvidia-smi -pl`로
  전력 상한을 조정 (드라이버 pod는 RHCOS 버전이 이름에 붙으므로
  `app.kubernetes.io/component=nvidia-driver` 라벨로 찾음 — `app=nvidia-driver-daemonset`
  라벨은 존재하지 않으니 주의)
- Grafana Tier1 "Power Draw per GPU" 패널에서 즉시 하락 확인 가능 (다음 스크레이프
  주기 ~30초 이내)

**실행**:
```bash
# 로컬에서
./harness.sh scenario3-powercap-start        # g6.2xlarge 준비 + power-load pod 배포 (기본: burst 3회 + idle 0.5초)
./harness.sh scenario3-powercap-apply 60     # 60W로 캡핑 — 테스트한 지점 중 가장 균형 잡힌 지점
./harness.sh scenario3-powercap-apply        # 인자 없이 실행하면 기본값(72W)으로 리셋
./harness.sh scenario3-powercap-stop         # pod 삭제 + 전력 한도 리셋

# idle 간격을 바꿔서 다시 테스트하고 싶다면 (재배포 필요 — pod의 command/args는 immutable)
oc delete pod power-load -n gpu-powercap-scenario-3
IDLE_SEC=1 ./harness.sh scenario3-powercap-start

# 또는 bastion에서 직접
~/scenario3-powercap-start.sh
~/scenario3-powercap-apply.sh 60
~/scenario3-powercap-stop.sh
```

**실측 결과 1 — 100% 포화 워크로드 (참고용, 현재 기본값 아님: `IDLE_SEC=0`과 동등)**:

| 전력 캡 | power.draw | 전력 절감 (vs 72W) | 처리량 (matmul/sec) | 성능 손실 (vs 72W) | 손실/절감 비율 |
|---|---|---|---|---|---|
| 72W (기본) | 71.58W | — | 10.66 | — | — |
| 65W | 65.11W | -9.7% | 9.44 | -11.4% | 1.18x |
| 60W | 59.61W | -16.7% | 8.60 | -19.3% | 1.16x |
| 50W | 49.86W | -30.6% | 6.26 | -41.3% | 1.35x |

**실측 결과 2 — 버스티 워크로드, `IDLE_SEC=0.5` (현재 기본값, 권장)**:

| 전력 캡 | 평균 power.draw (20샘플/5초) | 전력 절감 (vs 72W) | 처리량 (req/sec) | 성능 손실 (vs 72W) | 손실/절감 비율 |
|---|---|---|---|---|---|
| 72W (캡 없음) | 51.02W | — | 1.31 | — | — |
| 60W | 47.74W | -6.4% | 1.225 | -6.5% | **1.02x (거의 1:1)** |
| 50W | 43.27W | -15.2% | 1.08 | -17.6% | 1.16x |
| 45W | 40.72W | -20.2% | 1.01 | -22.9% | 1.13x |

Thanos Querier(`DCGM_FI_DEV_POWER_USAGE`, Grafana가 실제로 읽는 동일
데이터소스)로도 교차 확인 완료 — nvidia-smi 실측치와 일치, Grafana "Power
Draw per GPU" 패널에 하락이 그대로 반영됨.

**실측 결과 3 — idle을 너무 길게 주면(`IDLE_SEC=3`) 캡핑 자체가 무의미해짐 (교훈)**:

`IDLE_SEC=3`으로 재배포하고 측정했더니 캡 없는 상태의 평균 소비전력이 이미
**38.94W**까지 떨어졌다 — L4의 최소 설정 가능 전력 한도(`power.min_limit=40W`)
보다도 낮다. 즉 워크로드가 이미 대부분 쉬고 있어서, 어떤 유효한 캡(40~72W)을
걸어도 평균 전력에 측정 가능한 영향이 없다 (캡이 워크로드의 자연스러운 평균
소비량보다 항상 높은 상태). 참고로 pod 자체가 아예 없을 때 진짜 유휴 전력은
**16.72W**로, 0.5초 idle 구간 동안에는 이 수준까지 못 내려간다는 것도 확인됨
(L4의 P-state 전환에 초 단위 지연이 있는 것으로 추정 — 0.5초는 너무 짧아
완전히 못 내려가고, 3초는 너무 길어서 캡이 걸릴 일 자체가 없어짐).

**L4 결론**: 버스티 패턴으로 바꾸자 손실/절감 비율이 100% 포화 대비 확실히
개선됐다 (최악 1.35배 → 최선 1.02배). 다만 이 특정 GPU(L4)·워크로드
조합에서는 테스트한 어떤 지점에서도 "성능 손실 < 전력 절감"(비율 1.0 미만)을
달성하지는 못했다 — **60W가 사실상 손익분기점(1.02배)으로 테스트한 지점 중
가장 합리적**이다.

**실측 결과 4 — 더 큰 전력 예산 카드(A10G, g5.2xlarge)로 바꾸면 진짜 이득 구간이 나타남**:

L4가 안 됐던 이유가 "카드 자체의 전력 예산이 작아서 깎아낼 부스트 여유가
없다"는 가설을 세우고, 이미 클러스터에 떠 있던 g5.2xlarge(NVIDIA A10G,
`power.min_limit=100W` / `power.default_limit=power.max_limit=300W`) 노드에
같은 버스티 워크로드(`DEMO_NAMESPACE=gpu-powercap-a10g
POWERCAP_INSTANCE_TYPE=g5.2xlarge ./harness.sh scenario3-powercap-start`)를
배포해 재검증했다. **재현성 확인을 위해 각 지점을 독립적으로 두 번씩
측정**:

| 전력 캡 | 평균 power.draw | 전력 절감 | 처리량 (req/sec) | 성능 손실 | 손실/절감 비율 (1차 → 2차) |
|---|---|---|---|---|---|
| 300W (캡 없음) | 144.62W → 144.57W | — | 1.56 → 1.56 | — | — |
| **120W** | 106.78W → 105.18W | -26.2% → -27.3% | 1.19 → 1.195 | -23.7% → -23.4% | **0.90x → 0.86x (평균 0.88x, 유리)** |
| 100W (하한) | 99.61W → 97.76W | -31.1% → -32.4% | 0.9925 → 0.995 | -36.4% → -36.2% | 1.17x → 1.12x (평균 1.15x, 다시 불리) |

베이스라인·120W·100W 모두 두 시도 간 오차 2% 이내로 잘 재현됐다. **120W가
명확한 손익분기점 아래(평균 0.88배)** — L4에서는 어떤 지점에서도 못 넘던
선을 A10G에서는 넘었다. 다만 100W(하한)까지 더 눌러버리면 L4와 같은 패턴으로
다시 불리해진다 — "부스트 구간만 깎으면 이득, 정상 동작 구간까지 파고들면
다시 손해"라는 곡선이 두 GPU에서 일관되게 관찰됨.

**종합 결론**: 전력 캡의 유불리는 GPU 한 대로 일반화할 수 없고, **카드의
절대 전력 예산과 캡을 얼마나 세게 거느냐에 달려 있다.** 이번 실측 기준:
- 작은 카드(L4, 40~72W): 테스트 범위 안에서 이득 구간을 찾지 못함 (최선
  60W, 손익분기점 수준인 1.02배)
- 큰 카드(A10G, 100~300W): 명확한 이득 구간 존재 (120W, 평균 0.88배) —
  단, 하한(100W)까지 밀어붙이면 다시 손해로 역전
데모에서는 "전력을 줄이면 무조건 이득"이라고 과장하지 말고, 워크로드의
duty cycle(포화 vs 버스티), 카드의 절대 전력 예산, 그리고 캡의 세기가
결과를 어떻게 바꾸는지를 데이터로 함께 보여주는 걸 추천 — 아래 산점도가
이 메시지를 한 장으로 보여준다 (전력 절감 vs 성능 손실, 손익분기선 포함,
L4/A10G 3개 시리즈).

**[전력 절감 vs 성능 손실 산점도 →](https://claude.ai/code/artifact/b63a995b-eca6-469c-8dda-804549a742b9)**

---

## 시나리오 4 — GPU 노드 장애 격리 및 자동 재배치

> **상태: harness에 완전히 반영 + 실측 검증 완료 (2026-08-14).**

**보여주는 것**: GPU 노드에 장애가 생기면, 인프라팀이 그 노드를 격리(cordon &
drain)하는 것만으로 — 사람이 워크로드를 직접 옮기지 않아도 — 자동으로 다른
정상 GPU 노드로 재배치된다. 문서 [시나리오 1]의 "인프라팀 통제 액션"(Cordon &
Drain 처리, 과부하 Pod 강제 종료 후 정상 노드로 재배치)을 그대로 재현한다.

**왜 실제 하드웨어 장애를 재현하지 않는가**: `nvidia-smi`로 XID 에러를
안전하게 강제 유발하는 방법이 없고, 클라우드 GPU에 실제 손상을 유발하는 건
당연히 불가능하다. 대신 "DCGM이 이 노드에서 XID 에러를 반복 감지했다"는
상황을 가정하고, 인프라팀의 **대응 조치**(cordon & drain)를 그대로 실행하는
방식으로 시연한다 — 시나리오2에서 이미 보여준 XID Errors 패널/알람 구조와
자연스럽게 이어지는 스토리.

**구성**:
- `fault-workload`는 **bare Pod가 아니라 Deployment(replica=1)**로 배포 —
  이래야 노드가 drain될 때 컨트롤러가 pod를 자동으로 재생성해서 다른 노드로
  옮겨간다 (bare Pod는 삭제되면 그냥 사라지고 스스로 안 살아남)
- 특정 GPU 플레이버에 고정하지 않음 (`nodeSelector` 없음) — 스케줄러가 g5든
  g6든 여유 있는 아무 GPU 노드에나 배치
- 시나리오1·2·3과 동일한 PyTorch 8192×8192 행렬곱 부하 컨테이너 재사용

**실행**:
```bash
# 로컬에서
./harness.sh scenario4-fault-start      # fault-workload 배포, 어느 노드에 떴는지 확인
./harness.sh scenario4-fault-trigger    # 그 노드를 cordon+drain -> 자동 재배치 확인
./harness.sh scenario4-fault-stop       # 정리 (deployment 삭제 + 모든 GPU 노드 uncordon)

# 또는 bastion에서 직접
~/scenario4-fault-start.sh
~/scenario4-fault-trigger.sh
~/scenario4-fault-stop.sh
```

**지켜볼 것**:
```bash
oc get nodes -l nvidia.com/gpu.present=true -w   # cordon되는 노드의 SchedulingDisabled 확인
oc get pods -n gpu-fault-scenario-4 -o wide -w   # pod가 다른 노드로 재배치되는 것 확인
```
- Grafana Tier1 "GPU Utilization by Node" 패널 — 격리된 노드는 0%로 떨어지고,
  재배치된 노드는 100%로 올라가는 게 실시간으로 보임

**실측 결과** (2026-08-14): `fault-workload`가 `ip-10-0-17-5.ec2.internal`에서
실행 중이던 상태에서 트리거 실행 → cordon → drain(daemonset 제외 pod들 축출,
`fault-workload` 포함) → Deployment 컨트롤러가 즉시 새 pod 생성 →
`ip-10-0-1-245.ec2.internal`(다른 GPU 노드)에 자동 스케줄 → 약 1분 이내
`Running` 전환 확인. Thanos Querier로 GPU 사용률 교차 확인 — 원래 노드
0%, 새 노드 100%로 정확히 반영됨.

**타이밍**: 전체 과정 **1분 이내** — 시나리오1·3(각 ~10분 대기)과 달리 새
인스턴스 프로비저닝이 필요 없어서 훨씬 빠르다. 다만 g5·g6 GPU 노드가 각각
1대씩 이미 떠 있어야 한다 (재배치 받을 "정상 노드"가 있어야 하므로) — 시나리오
1을 실행한 직후처럼 GPU MachineSet이 일시적으로 2대로 늘어나 있는 상태이거나,
평소 기본 상태(각 1대)면 충분하다.

**정리**: `scenario4-fault-stop.sh`가 deployment 삭제와 GPU 노드 전체
uncordon을 같이 처리하므로, 트리거 도중에 중단하더라도 이 스크립트 한 번으로
클러스터가 깨끗한 상태로 돌아온다.

---

## 시나리오 5 — 비효율 코드 탐지 (Bad Code Penalty)

> **상태: harness 반영 + 실측 검증 완료 (2026-08-14, 이후 2026-08-20에 순차
> 실행 방식으로 재작성 — 새 AWS 샌드박스 계정의 G/VT vCPU 쿼터가 4라서
> GPU 노드를 동시에 1대만 띄울 수 있어, 원래의 "두 pod 동시 실행 후 비교"
> 방식이 그대로는 안 됨. 아래 실측 결과는 이전(2대 동시 가능했던) 계정
> 기준이고, 순차 실행 버전의 재검증은 아직 전).**
> PriorityClass 하향 + Preemption 실효성 증명은 [시나리오 6](#시나리오-6--priorityclass-하향-및-preemption-실효성-증명)에서 이어짐.

**보여주는 것**: 똑같은 학습 코드인데 `DataLoader`의 `num_workers` 설정
하나 차이로 비싼 GPU를 얼마나 놀리는지를 실측 그래프로 비교한다. 문서
[문서 시나리오 3]의 "Data Loader 병목으로 GPU가 놀고 있다"는 상황을 실제
PyTorch 메커니즘으로 재현한다 (인위적인 `sleep`으로 흉내내는 게 아니라, 진짜
`DataLoader` 워커 수 설정 차이).

**왜 `num_workers`로 비교하는가**: `num_workers=0`이면 메인 프로세스
혼자 샘플을 **한 개씩 순차적으로** 준비한다 — 배치 하나 다 준비될 때까지 GPU는
완전히 손 놓고 기다린다. `num_workers>0`이면 별도 워커 프로세스들이 **GPU가
지금 배치를 계산하는 동안 다음 배치를 미리(prefetch) 준비**해서, GPU가 노는
시간이 크게 줄어든다. 이건 실제 "왜 내 GPU 사용률이 낮지" 문제의 가장 흔한
원인이자, 가장 흔한 해법이다.

**구성**:
- 두 pod가 **동일한 코드**를 돌림 — `Dataset.__getitem__`마다 0.2초 sleep으로
  실제 이미지 디코딩/증강 비용을 흉내내고, 매 배치(32개)마다 4096×4096
  행렬곱을 10회 반복하는 "학습 스텝"을 수행
- `bad-code-workload`: `num_workers=0`
- `efficient-workload`: `num_workers=4`
- **주의**: `num_workers>0`이면 PyTorch가 `/dev/shm`(공유 메모리)으로 텐서를
  워커-메인 프로세스 간 주고받는데, 컨테이너 기본 `/dev/shm`은 보통 64MB로
  너무 작아서 `Bus error` / `DataLoader worker exited unexpectedly`로
  크래시한다 — pod에 `emptyDir(medium: Memory, sizeLimit: 1Gi)`를
  `/dev/shm`에 마운트해서 해결함 (2026-08-14 실측으로 발견/수정)

**실행 (순차 버전, GPU 노드 1대 기준)**: `scenario5-badcode-start` 하나가
`bad-code-workload`를 배포 → `OBSERVE_SECONDS`(기본 60초) 관찰 → step 수
기록 → 삭제 → 곧바로 `efficient-workload` 배포 → 같은 시간 관찰 → 삭제 →
마지막에 두 결과를 나란히 출력한다 (GPU 1장이라 동시 실행이 안 되니, 같은
시간 동안 각각 따로 재서 비교).
```bash
# 로컬에서
./harness.sh scenario5-badcode-start      # 두 워크로드를 순차로 돌리고 처리량 비교까지 자동 출력
./harness.sh scenario5-badcode-stop       # 안전망 (start가 이미 각 단계에서 정리함)

# 관찰 시간 조정
OBSERVE_SECONDS=120 ./harness.sh scenario5-badcode-start
```

**지켜볼 것**:
- `scenario5-badcode-start` 자체 출력 — 각 워크로드가 같은 시간 동안 몇
  step까지 갔는지, 배율(speedup)까지 마지막에 계산해서 보여줌
- Grafana Tier1 "GPU Compute vs Memory Utilization (Cluster Avg)" / Tier2
  "Stall Pattern: High Memory, Low Compute" 패널 — 두 구간의 이용률 차이를
  시간순으로 확인 가능

**실측 결과 (이전 계정 · 동시 실행 버전, 2026-08-14, 4분간 관찰)**:

| 워크로드 | 처리량(스텝, 동일 시간) | 평균 GPU_UTIL | 평균 MEM_COPY_UTIL |
|---|---|---|---|
| `bad-code-workload` (num_workers=0) | 40 | **0%** | **0%** |
| `efficient-workload` (num_workers=4) | 160 (4배) | **12%** | **5.25%** |

처리량 4배 차이가 그대로 GPU 이용률 차이로 이어졌다 — `bad-code-workload`는
관찰 window 내내 GPU_UTIL/MEM_COPY_UTIL이 사실상 0%에 머물러서, 문서가
말하는 "비싼 GPU를 사놓고 놀리고 있다"는 상황을 정량적으로 보여준다. (문서
원문은 "메모리 90%↑, 연산만 주기적으로 0%" 패턴을 가정하지만, 실측해보니 이
워크로드에서는 메모리 활동도 연산과 함께 거의 0으로 같이 떨어진다 — 그래도
핵심 메시지인 "코드가 나쁘면 GPU가 논다"는 동일하게 증명된다.)

---

## 시나리오 6 — PriorityClass 하향 및 Preemption 실효성 증명

> **상태: harness 반영 + 실측 검증 완료 (2026-08-14).**

**보여주는 것**: 시나리오 5에서 "비효율 코드"로 지적된 팀에게 인프라팀이
PriorityClass를 Low로 낮췄다고 하자 — 그런데 이게 진짜 효과가 있나?
자원이 부족해지는 순간, Kubernetes가 **자동으로** 그 팀의 pod를 강제
축출(Preemption)하고 정상 우선순위 워크로드에게 자리를 내주는 것까지
실제로 확인한다. 문서의 "PriorityClass Low 하향 → 자원 부족 시 즉시
Preemption 대상"을 그대로 재현.

**핵심 설계 — 오토스케일러와의 경쟁 상태 제거**: `bad-code-workload`와
`legitimate-workload`를 같은 GPU 플레이버(g5.2xlarge, 노드 1대/GPU 1장)에
몰아넣어서 "자리가 없어야" Preemption이 의미가 있는데, 이대로 두면
`MachineAutoscaler`가 새 노드를 추가해서 Preemption 없이도 해결해버릴 수
있다(경쟁 상태). 그래서 `scenario6-preempt-start.sh`가 g5
MachineAutoscaler의 `max`를 **현재 replica 수(1)로 일시적으로 고정**해서
오토스케일 자체를 원천 차단한다 — Preemption이 유일한 해결책이 되도록.
`scenario6-preempt-stop.sh`가 다시 2로 복원한다.

**구성**:
- `PriorityClass/low-priority-team` (value: -1000000) — "시나리오 5에서
  적발된 팀에게 부여" 컨셉
- `bad-code-workload`: `priorityClassName: low-priority-team`, g5.2xlarge
  고정, GPU 1장 요청 — 유일한 GPU를 선점
- `legitimate-workload`: 기본 우선순위(PriorityClass 미지정, 기본값 0 >
  -1000000), 동일하게 g5.2xlarge 고정, GPU 1장 요청

**실행**:
```bash
# 로컬에서
./harness.sh scenario6-preempt-start      # bad-code-workload가 low-priority로 GPU 선점
./harness.sh scenario6-preempt-trigger    # legitimate-workload 배포 -> Preemption 확인
./harness.sh scenario6-preempt-stop       # 정리 + MachineAutoscaler max 원복(2)
```

**지켜볼 것**:
```bash
oc get pods -n gpu-preempt-scenario-6 -w
oc get events -n gpu-preempt-scenario-6 --field-selector reason=Preempted
```

**실측 결과** (2026-08-14): `bad-code-workload`가 `low-priority-team`으로
g5의 유일한 GPU에서 `Running` 중인 상태에서 `legitimate-workload`(기본
우선순위) 배포 → **약 34초 만에** 다음 이벤트 확인:
```
Normal   Preempted   pod/bad-code-workload   Preempted by pod 9a6d9af0-... on node ip-10-0-1-245.ec2.internal
```
`bad-code-workload`는 축출되어 사라졌고(`Gone`), `legitimate-workload`가
그 GPU에서 `Running`으로 전환됨. Kubernetes 이벤트 로그에 "Preempted by
pod ..."가 명시적으로 남아서, 우연한 재시작이 아니라 **진짜 Preemption이
일어났다는 증거**가 된다.

**정리**: `scenario6-preempt-stop.sh` 한 번으로 pod 삭제 +
MachineAutoscaler max 원복(2)까지 다 처리됨. 트리거 도중 중단해도 이
스크립트로 클러스터가 원래 상태(각 플레이버 min=1/max=2)로 돌아온다.

---

## 시나리오 7 — 비용 초과 대응 (Chargeback & Quota)

> **상태: harness 반영 + 실측 검증 완료 (2026-08-14).**

**보여주는 것**: 팀이 예산을 다 썼다고 인프라팀이 판단하면, `ResourceQuota`
하나로 그 팀이 더 이상 GPU를 못 늘리게 즉시 막을 수 있다 — 그리고 이건
스케줄링을 기다릴 필요도 없이 **API 요청 즉시(admission 단계에서) 거부**된다.
시나리오 4·6(스케줄링/Preemption 기반)과 달리 대기 시간이 전혀 없는 가장
빠른 시나리오.

**비용 가시성**: Tier1 "Fleet Overview" 행에 **"Estimated GPU Cost ($/hr)"**
패널 추가 — `sum(할당된 GPU) × $1.10`(g5.2xlarge·g6.2xlarge 온디맨드 단가
사이의 가정 블렌디드 요금)로 계산한 **추정치**다. 실제 청구 시스템과 연동된
게 아니라 일러스트레이션 목적임을 패널 description에도 명시해뒀다 — 데모에서
"이게 실제 AWS 청구액과 정확히 일치한다"고 과장하지 말 것.

**구성**:
- `team-workload-1`: GPU 1장 요청, 배포 (그 팀의 "이미 쓰고 있는" 사용량 흉내)
- 인프라팀이 `ResourceQuota`(`requests.nvidia.com/gpu: "1"`)를 적용 — 현재
  사용량과 정확히 같은 값으로 캡핑 (문서상 "예산의 70% 초과 시 즉시 제한"의
  종착점)
- `team-workload-2`: 추가로 GPU 1장을 더 요청하려는 시도 — 이미 quota가
  꽉 차 있어서 API 서버가 **즉시 거부**

**실행**:
```bash
# 로컬에서
./harness.sh scenario7-chargeback-start      # team-workload-1 배포 + quota 적용
./harness.sh scenario7-chargeback-trigger    # team-workload-2 시도 -> 즉시 거부 확인
./harness.sh scenario7-chargeback-stop       # 정리
```

**실측 결과** (2026-08-14): `ResourceQuota`가 `requests.nvidia.com/gpu: "1"`
로 적용된 상태(사용량도 1)에서 `team-workload-2` 배포 시도 →
```
Error from server (Forbidden): error when creating "STDIN": pods "team-workload-2" is
forbidden: exceeded quota: gpu-quota, requested: requests.nvidia.com/gpu=1,
used: requests.nvidia.com/gpu=1, limited: requests.nvidia.com/gpu=1
```
pod 자체가 생성조차 안 됨(`oc get pods`에 안 뜸) — 스케줄러가 개입하기도
전에 API 서버 admission 단계에서 막힌 것. 시나리오 4(cordon+drain, ~1분),
시나리오 6(preemption, ~34초)보다도 빠르고, 대기/경쟁 상태 걱정이 아예 없는
가장 결정적인(deterministic) 시나리오다.

**아직 안 한 것 — Node affinity(야간/Spot 전용)**: 문서의 두 번째 조치안
("야간 시간대나 남는 Spot 인스턴스에서만 작업이 돌도록 Node affinity 강제
변경")은 미구현 — 지금 클러스터의 GPU MachineSet이 On-Demand 인스턴스라
실제 Spot 인스턴스 노드가 없고, 새로 만들려면 별도 MachineSet 작업이
필요해서 범위 밖으로 뒀다.

---

## 시나리오 8 — KServe + vLLM 유휴 회수 (Scale-to-Zero)

> **상태: 설계 확정(플랫폼 공식 지원 패턴 기준), harness 구현·실측 검증 진행 중
> (2026-08-20 작성 — 최초 버전은 커스텀 폴링 스크립트였으나, 실제 서빙
> 플랫폼(KServe)이 이 문제를 어떻게 네이티브로 푸는지 보여주는 쪽으로
> 재설계함. 폴링 기반 "실측 후 회수" 아이디어 자체는 [시나리오 9](#시나리오-9--동적-할당--전체-자원-회수-dynamic-allocation--full-reclaim)에
> 그대로 살아있음).**

**보여주는 것**: 실제 GPUaaS 플랫폼이라면 유휴 GPU를 사람이 지켜보다가
지우는 게 아니라, **서빙 플랫폼 자체가 트래픽을 보고 자동으로 반납**한다.
KServe로 vLLM 모델을 서빙하다가 요청이 안 오면 자동으로 replica가 0으로
줄어서(GPU 완전 반납) 다른 팀이 쓸 수 있게 되고, 요청이 다시 오면 자동으로
떠오른다.

**왜 Knative Serverless가 아니라 KEDA인가**: KServe의 scale-to-zero는
원래 Knative(Serverless) 배포 모드의 기능인데, 이 클러스터의 RHOAI는
Service Mesh 의존성을 피하려고 `remote/rhoai.sh`에서 일부러
`RawDeployment` 모드로 설치돼 있다 (`defaultDeploymentMode: RawDeployment`,
`serving.managementState: Removed`). RawDeployment는 원래 scale-to-zero를
지원 안 하지만, Red Hat이 2025년 하반기에 공식 문서화한 방법이 있다 —
**OpenShift Custom Metrics Autoscaler(KEDA 기반) 오퍼레이터**를 추가해서
KServe의 기본 HPA를 끄고(`serving.kserve.io/autoscalerClass: external`)
KEDA `ScaledObject`로 대체하면, Service Mesh/Knative 없이도
`minReplicaCount: 0`까지 스케일다운된다. 이 클러스터에 이미 깔려있는
Service Mesh 회피 결정을 안 뒤엎는 방법이라 채택함.

**구성 (계획)**:
- `openshift-custom-metrics-autoscaler-operator` 설치 (네임스페이스
  `openshift-keda`, channel `stable`) + `KedaController` CR
- RHOAI의 실제 vLLM `ServingRuntime`으로 `Qwen/Qwen2.5-0.5B-Instruct`
  (5억 파라미터급 소형 공개 모델 — 로드/스케일업이 빨라 라이브 데모에 적합)
  서빙하는 `InferenceService` 배포, `RawDeployment` 모드 유지
- `KEDA ScaledObject`가 Thanos Querier의 vLLM 큐 메트릭
  (`vllm:num_requests_waiting`) 또는 DCGM GPU 사용률을 트리거로 삼아
  0 ↔ N(기본 2) 스케일

**실행 (구현 완료 후 갱신 예정)**:
```bash
# 로컬에서
./harness.sh scenario8-kserve-vllm-start      # InferenceService + KEDA ScaledObject 배포
./harness.sh scenario8-kserve-vllm-load       # 실제 추론 요청 전송 -> 스케일업 확인
./harness.sh scenario8-kserve-vllm-stop       # 정리
```

**검증할 것**: replica가 실제로 0에서 시작(또는 유휴 후 0으로 감), 실제
추론 요청을 보내면 KEDA가 스케일업해서 요청이 성공, 요청을 멈추면 idle
윈도우 후 다시 0으로 스케일다운 — 이 세 전환을 전부 라이브로 실측 확인한
뒤 실측 타이밍(스케일업/다운 소요 시간)을 이 섹션에 기록할 예정.

Sources: [How to set up KServe autoscaling for vLLM with KEDA](https://developers.redhat.com/articles/2025/09/23/how-set-kserve-autoscaling-vllm-keda),
[Custom Metrics Autoscaler on OpenShift](https://www.redhat.com/en/blog/custom-metrics-autoscaler-on-openshift),
[Boost AI efficiency with GPU autoscaling on OpenShift](https://developers.redhat.com/articles/2025/08/12/boost-ai-efficiency-gpu-autoscaling-openshift)

---

## 시나리오 9 — Kueue + Dynamic Resource Allocation (DRA)

> **상태: 설계 확정, harness 구현·실측 검증 진행 중 (2026-08-20 작성 — 이전
> 버전은 MachineAutoscaler 기반 "동적 할당 + 회수"였는데, 그 발상 자체는
> 시나리오 1(할당)·시나리오 8의 옛 버전(회수)로 이미 각각 다뤄지고 있어서,
> 대신 Kueue + DRA라는 더 진짜 GPUaaS 플랫폼다운 스케줄링 계층을 보여주는
> 쪽으로 새로 설계함).**

**보여주는 것**: 지금까지의 시나리오들은 전부 Kubernetes 기본 스케줄러 +
`nvidia.com/gpu: N` 정수 카운팅에 의존한다 (Pending → MachineAutoscaler,
PriorityClass → Preemption 등). 진짜 멀티테넌트 GPUaaS 플랫폼은 그 위에
**Kueue**(작업 큐잉 — 팀별 쿼터·공정 분배·우선순위를 스케줄러 이전 단계에서
관리)와 **DRA**(Dynamic Resource Allocation — GPU를 device-plugin의 단순
정수 카운팅이 아니라 `ResourceClaim`이라는 구조화된 API로 요청/할당하는
Kubernetes 최신 표준 방식, OpenShift 4.21부터 GA)를 올려서 훨씬 정교하게
관리한다.

**주의 — MIG(GPU 슬라이싱)는 이 시나리오에 안 들어감**: DRA가 유명한 이유
중 하나가 NVIDIA MIG(GPU 하나를 여러 개로 쪼개 쓰는 것)와의 조합인데,
이 클러스터의 GPU 플레이버(A10G, L4)는 **하드웨어 자체가 MIG를 지원하지
않는다**(MIG는 A100/H100급 데이터센터 GPU 전용 회로가 있어야 함 — 실측
확인 완료, 2026-08-20). 그래서 이 시나리오는 "GPU를 쪼개 쓰기"가 아니라,
**온전한 GPU 한 장 단위 요청도 Kueue의 큐/쿼터를 거쳐서, DRA의 구조화된
클레임 API로 할당된다**는 부분에 집중한다.

**흐름 (계획)**:
1. Kueue(Red Hat build of Kueue) 설치 — 팀별 `LocalQueue` + GPU 쿼터를 가진
   `ClusterQueue` 구성 (리소스 플레이버는 DRA `DeviceClass`를 참조)
2. 두 팀이 동시에 GPU를 요청하는 Job을 여러 개 제출 — 합쳐서 쿼터 초과
3. 쿼터를 넘는 Job들은 스케줄러한테 넘어가기도 전에 **Kueue admission
   단계에서 대기열에 그대로 머무름** (Pending으로 스케줄러가 붙잡는 게
   아니라, Kueue가 애초에 스케줄러에 넘기지 않음) — `kubectl get workloads`로
   Admitted vs 대기 중인 워크로드를 구분해서 보여줌
4. 앞선 Job이 끝나서 쿼터가 비면 대기 중이던 Job이 **공정 분배/우선순위
   규칙에 따라** 자동으로 admit됨
5. 실제 GPU 할당은 `ResourceClaim`/`ResourceSlice`(DRA 오브젝트)로 이뤄짐 —
   `nvidia.com/gpu: 1` 같은 구식 정수 요청이 아니라 구조화된 클레임인 걸
   직접 확인

**harness 구현은 아직**: Kueue/DRA의 정확한 CRD 필드·API 버전을 이
클러스터의 실제 설치본 기준으로 확인한 뒤 스크립트를 작성할 예정 —
추측으로 YAML을 먼저 쓰지 않고, 이번 세션에서 계속 해온 대로 실제
클러스터에서 검증하며 만든다.

Sources: [Improve GPU utilization with Kueue in OpenShift AI](https://developers.redhat.com/articles/2025/05/22/improve-gpu-utilization-kueue-openshift-ai),
[Dynamic resource allocation goes GA in Red Hat OpenShift 4.21](https://developers.redhat.com/articles/2026/03/25/dynamic-resource-allocation-goes-ga-red-hat-openshift-421-smarter-gpu),
[Multitenant AI inference with dynamic resource allocation on OpenShift](https://developers.redhat.com/articles/2026/08/03/multitenant-ai-inference-dynamic-resource-allocation-openshift)

---

## 미구현 시나리오 (참고용, `openshift-monitoring` 문서 원본 번호 기준)

아래는 아직 harness에 자동화되어 있지 않은 시나리오들입니다. 감지 조건과
인프라팀 조치안은 문서에 정의되어 있으나, 실제 구현(PrometheusRule, 자동 통제
액션 등)은 없는 상태입니다.

### Green AI — RHCOS 기반 GPU 전력 절감

RHCOS(Red Hat Enterprise Linux CoreOS)의 불변성(Immutability)을 활용해
선언적으로 노드/GPU 전력을 통제하는 시나리오. 3가지 방법으로 구성:

1. **Node Tuning Operator(NTO) 기반 CPU Power Profile** — RHCOS 노드의 Tuned
   Custom Resource로 유휴 상태 CPU 전력 소비 제어. 개발/테스트 노드는
   `powersave` 프로필, 운영 노드는 `performance` 프로필 유지.
   > **AWS EC2 위에서는 측정 가능한 시나리오로 못 만든다 (2026-08-13 확인).**
   > 이 클러스터의 워커 노드에서 직접 확인한 결과:
   > - `/sys/class/powercap/`(RAPL — CPU 패키지 실제 소비 전력을 읽는 인터페이스)가
   >   **비어 있음**. AWS의 Nitro/KVM 하이퍼바이저가 RAPL MSR을 게스트 VM에
   >   패스스루하지 않기 때문 — 클라우드 VM 공통의 구조적 제약이지 OpenShift나
   >   RHCOS의 한계가 아니다.
   > - `/sys/devices/system/cpu/cpu0/cpufreq/`(governor를 `powersave`/`performance`로
   >   바꾸는 표준 리눅스 인터페이스) 디렉터리 자체가 **존재하지 않음** — 게스트
   >   커널에 cpufreq 서브시스템이 노출되지 않아, Tuned가 `powersave` 프로필을
   >   적용해도 바꿀 대상이 없는 사실상 no-op이 된다.
   > - `turbostat`도 MSR 접근이 막혀 있어 사용 불가.
   >
   > GPU 쪽(시나리오 3)이 됐던 이유는 NVIDIA가 NVML이라는 자체 관리 인터페이스로
   > GPU 하드웨어 전력 텔레메트리를 게스트에 직접 넘겨주기 때문 — AWS는 그 경로를
   > 열어두지만(GPU 인스턴스의 핵심 기능이니까), 범용 CPU 전력 관리 경로(RAPL/cpufreq)는
   > 클라우드 하이퍼바이저 대부분이 막아둔다. 이 시나리오를 실제로 측정하며 보여주려면
   > **베어메탈 RHCOS 노드**(물리 서버, 또는 RAPL을 패스스루하는 베어메탈 클라우드
   > 인스턴스)가 필요하다.
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
     - **주의**: 이건 일반론적 예시(대형 GPU/큰 전력 예산 기준)이고, 실제
       [시나리오 3]에서 g6.2xlarge(L4, 40~72W)로 실측했을 때는 이 유리한
       비율이 재현되지 않았다. 100% 포화 FP32 행렬곱에서는 72W→50W에서 전력
       30.6% 감소에 성능이 오히려 41.3% 더 많이 줄었고, 버스티(추론 서빙
       흉내, burst+idle) 패턴으로 바꿔도 최선의 경우(72W→60W)가 손실/절감
       거의 1:1(1.02배)에 그쳐 손익분기점 수준이었다 — "손실 < 절감"을
       테스트한 어떤 지점에서도 달성하지 못했다. 유휴/버스티 구간이 있는
       워크로드일수록, 그리고 절대 전력 예산이 클수록 이 이론이 잘 맞고,
       이미 작은 카드(L4 같은 저전력 카드)를 짧은 idle만 두고 돌리는
       워크로드에서는 잘 안 맞을 수 있다는 뜻 — 데모에서 과장된 주장을
       하지 않도록 [시나리오 3]의 실측 표를 함께 보여줄 것.
3. **Bare-metal / AWS Auto-Shutdown** — 주말·야간 시간대 미사용 RHCOS 워커
   노드를 완전 종료(Scale to 0 또는 IPMI Power-Off)해서 불필요한 전력 소모
   완전 차단.

- **현재 가시성만 있음**: Tier1 대시보드 "Total GPU Power Draw", "Power Draw
  per GPU" 패널 (Power & Memory Capacity 행)

---

## 참고

- 시나리오들은 서로 다른 네임스페이스(`gpu-autoscale-scenario-1`,
  `gpu-alert-scenario-2`, `gpu-powercap-scenario-3`, `gpu-fault-scenario-4`,
  `gpu-badcode-scenario-5`, `gpu-preempt-scenario-6`,
  `gpu-chargeback-scenario-7`)를 쓰므로 동시에
  진행해도 서로 간섭하지 않습니다. 단, 시나리오 6은 g5.2xlarge
  MachineAutoscaler의 max를 일시적으로 1로 낮추므로, 시나리오 1(같은
  g5.2xlarge를 쓰는 오토스케일링 데모)과는 동시에 진행하지 말 것.
- 알람 파이프라인은 OpenShift 기본 User Workload Monitoring이 아니라
  **독립적인 Prometheus + Alertmanager**로 분리되어 있습니다 (`gpu-monitoring`
  네임스페이스). 이유와 배경은 `harness/README.md`의
  "GPU monitoring / demo control-plane" 절 참고.
- 임계값/채널 등은 재배포 시 조정 가능:
  ```bash
  GPU_TEMP_THRESHOLD_C=70 SLACK_CHANNEL='#alert-demo' \
    SLACK_WEBHOOK_URL='...' ./harness.sh dcgm-alerts
  ```
