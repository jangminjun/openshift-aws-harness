# Lessons Learned

이 하네스(openshift-aws-harness)를 운영하며 겪은 이슈들을 현상/원인/해결책 순으로 기록.
MaaS 설치 자체의 더 상세한 이슈는 `basic-demo/lessonlearn.md`도 참고할 것
(이 문서와 서로 참조하는 항목이 있음).

## 1. `AWS_PROFILE`이 `config.env`에서 `export` 안 되어 있어서 엉뚱한(죽은) 계정으로 인증 시도

- **현상**: sandbox5462로 새 샌드박스를 받고 `config.env`의 `AWS_PROFILE`
  기본값만 바꾼 뒤 `./harness.sh bastion-up`을 실행하면
  `AuthFailure: AWS was not able to validate the provided access credentials`로
  즉시 실패. `AWS_PROFILE=ocp-sandbox7 aws sts get-caller-identity`는 방금
  직접 확인했을 때 정상 동작했는데도 실패함.
- **원인**: `config.env`에 `AWS_PROFILE="${AWS_PROFILE:-ocp-sandbox7}"`라고만
  적혀있고 `export`가 없었음. 이 리포의 어떤 스크립트도 `aws ... --profile`을
  명시적으로 넘기지 않고, 대신 `aws` CLI가 환경변수 `AWS_PROFILE`을 자동으로
  읽는 것에 의존함 — 그런데 `export` 안 된 변수는 `config.env`를 `source`한
  현재 셸 안에서만 보이는 지역 변수일 뿐, `aws`라는 별도 프로세스(자식
  프로세스)에는 전달되지 않음. 그 결과 `aws` CLI는 `~/.aws/credentials`의
  `[default]` 프로파일(죽은 예전 샌드박스의 키)로 조용히 폴백했고, AWS가 그
  키를 거부하면서 에러가 남. `CLUSTER_NAME=x ./harness.sh ...`처럼 명령어
  앞에 붙여서 실행하면 그 한 번은 자동으로 export되어 우연히 동작했기 때문에,
  지금까지 이 버그가 안 걸렸던 것으로 추정됨.
- **해결책**: `config.env`에서 `export AWS_PROFILE="${AWS_PROFILE:-...}"`로
  변경. **교훈**: 하네스 스크립트가 환경변수를 통해서만 외부 CLI에 설정을
  전달하는 구조라면(즉 `--profile`/`--region` 같은 명시적 플래그가 아니라면),
  `config.env`의 기본값 대입은 반드시 `export`를 붙일 것 — 안 그러면 기본값
  경로가 조용히 무력화된다.

## 2. RHOAI 3.5로 버전 올리면서 `install-rhoai-34.sh` → `install-rhoai-35.sh` 전환

- **현상**: 없음(사전 예방적 변경) — 사용자가 RHOAI 3.4 대신 3.5를 요청.
- **원인/확인**: `RHOAI-Toolkit/scripts/`에 `install-rhoai-35.sh`가 이미
  존재하고, `--skip-admin-user`/`--skip-node-scaling`/`--channel` 등
  `maas.sh`가 쓰는 CLI 플래그가 3.4 스크립트와 동일함을 확인 후 교체.
- **해결책**: `config.env`/`rhoai.sh`/`harness.sh`/`maas.sh`/`README.md`의
  `RHOAI_CHANNEL` 기본값을 `stable-3.4`→`stable-3.5`로, `maas.sh`가 실행하는
  스크립트를 `install-rhoai-35.sh`로 일괄 변경. **참고**: RHOAI 3.5는 MaaS
  구현이 `kserve.modelsAsService` DSC 컴포넌트에서 `aigateway` 컴포넌트로
  바뀜(External OIDC, body-based 모델 라우팅 등 추가) — `maas.sh`의 기존
  DSC 패치 로직(`kserve.modelsAsService.managementState` 체크)은 3.5에서는
  해당 필드가 애초에 안 쓰이므로 조건이 그냥 스킵될 뿐 오작동은 없지만,
  향후 "이미 aigateway가 활성화된 DSC인지" 체크로 갱신할 필요가 있음(아직
  안 함 — 이번 빌드는 매번 새 DSC를 생성하는 케이스라 문제가 안 됨).

## 3. 와일드카드 인증서가 `*.apps.` 없이 잘못 발급 (basic-demo/lessonlearn.md #23와 동일 버그, 재발)

- **현상**: `harness.sh maas` 실행 후 `authentication`/`console` 클러스터
  오퍼레이터가 `Degraded=True`, 메시지는
  `x509: certificate is valid for *.myocp.sandbox5462.opentlc.com, ...,
  not oauth-openshift.apps.myocp.sandbox5462.opentlc.com`.
- **원인**: `install-rhoai-35.sh`의 Let's Encrypt 설정 단계가
  `Certificate/apps-wildcard-cert`(namespace `openshift-ingress`)를
  `dnsNames: ["*.myocp.sandbox5462.opentlc.com"]`(`.apps.` 빠짐)로 생성함.
  DNS-01 챌린지가 300초 안에 못 끝나서(#4 참고) self-signed 폴백으로
  넘어갔는데, 그 폴백도 이 잘못된 도메인으로 인증서를 만들어서 실제
  `*.apps.<domain>` 라우트들과 SAN이 안 맞음. `basic-demo/lessonlearn.md`
  #23에서 이미 같은 근본 원인(`RHOAI-Toolkit`의
  `wildcard-certificate.yaml.tmpl`이 `CLUSTER_DOMAIN`을 재확인 없이 그대로
  써서 `.apps.`를 안 붙임)이 밝혀졌었는데, 툴킷 쪽 수정이 아직 반영 안 된
  버전이라 재발함.
- **해결책**: `oc patch certificate apps-wildcard-cert -n openshift-ingress
  --type=merge -p '{"spec":{"dnsNames":["apps.<domain>","*.apps.<domain>"]}}'`로
  정정 후 cert-manager가 재발급 시도하도록 둠. **교훈**: `RHOAI-Toolkit`을
  새 버전으로 갈아탈 때마다 이 버그가 아직 고쳐졌는지 재확인할 것 — 고쳐질
  때까지는 매번 수동 패치가 필요.

## 4. Let's Encrypt DNS-01 challenge가 반복적으로 "secondary validation: DNS problem: networking error" 로 실패

- **현상**: #3을 고쳐서 도메인을 정정한 뒤에도, cert-manager의 DNS-01
  챌린지가 여러 번 재시도해도 계속
  `acme: authorization error ...: DNS problem: networking error looking up
  TXT for _acme-challenge.apps.<domain>`로 `invalid` 상태가 됨.
- **원인 (추정)**: Route53 호스티드존 자체의 NS 위임은 공인 리졸버(8.8.8.8)
  기준으로 정상 확인됨(`dig NS`가 AWS 네임서버 4개를 정확히 반환) — 위임
  설정 자체는 문제 없음. 가장 유력한 원인은 이 서브도메인(`sandbox5462.
  opentlc.com`)이 생성된 지 얼마 안 돼서(챌린지 시도 시점 기준 ~40분),
  Let's Encrypt의 글로벌 2차 검증 지점(secondary validation vantage point)
  들 중 일부가 아직 전파를 못 따라잡았을 가능성. 확정적 원인 규명은 못 함 —
  시간이 더 지나면 저절로 해결될 가능성이 높은, 재현하기 어려운 타이밍
  이슈로 보임.
- **해결책 (임시)**: 클러스터 오퍼레이터 정상화가 급했기 때문에, 올바른
  도메인으로 self-signed 인증서를 직접 만들어 `apps-wildcard-tls`/
  `default-gateway-tls` 시크릿에 즉시 적용(→ 근본 수정은 #5). **주의**:
  실패한 `CertificateRequest`를 지워도 cert-manager가 자동으로 새
  Order/Challenge를 곧바로 다시 만들지는 않음(5분 이상 관찰했지만 재시도
  없었음) — Certificate가 이미 `Ready=False`인 채로 유효한 시크릿을 가지고
  있으면 재발급을 스스로 트리거하지 않는 것으로 보임. 정말 신뢰된 인증서로
  교체하고 싶다면 대상 시크릿(`apps-wildcard-tls` 등) 자체를 삭제해서
  cert-manager가 "시크릿이 없음"으로 인식하고 처음부터 재발급을 시작하게
  만들어야 함(단, 재발급이 다시 실패하면 그 사이 클러스터 오퍼레이터가 다시
  Degraded로 돌아갈 수 있으니 주의). **교훈**: 방금 만든 Route53
  서브도메인에서 Let's Encrypt DNS-01이 반복 실패하면, 위임 설정 자체보다
  "전파 시간 부족"을 먼저 의심하고, 급하면 self-signed로 임시 우회한 뒤
  시간을 두고 시크릿을 지워서 수동으로 재시도할 것 — cert-manager의 자동
  재시도만 기다려선 안 됨.

## 5. self-signed 폴백 인증서가 `CA:TRUE`+EKU 없음으로 발급되어 `authentication` 오퍼레이터가 계속 거부함

- **현상**: #4의 임시 조치로 도메인이 맞는 self-signed 인증서를 넣었는데도
  `authentication` 오퍼레이터의 `RouterCertsDegraded` 컨디션이 안 없어짐.
  메시지: `secret/v4-0-config-system-router-certs.spec.data[apps.<domain>]
  -n openshift-authentication: no server certificates found`. 오퍼레이터
  파드를 강제 재시작해도 즉시 같은 결과로 재평가됨 (캐시 문제 아님을 확인).
- **원인**: `openssl req -x509 -newkey rsa:2048 ...`를 확장자(extension)
  지정 없이 그대로 실행하면, 이 환경의 기본 OpenSSL 설정이 `Basic
  Constraints: critical, CA:TRUE`로, Extended Key Usage는 아예 없이
  인증서를 발급함. OpenShift의 `RouterCertsDomainValidationController`는
  이런 "CA 인증서"를 TLS 서버 인증서로 인정하지 않고 "서버 인증서가 없음"
  으로 판단해서 계속 Degraded 처리함.
- **해결책**: 명시적 `[v3_req]` 확장자 섹션(`basicConstraints=critical,
  CA:FALSE`, `keyUsage=critical,digitalSignature,keyEncipherment`,
  `extendedKeyUsage=serverAuth`)을 지정해서 재발급. 적용 후 에러 메시지가
  `no server certificates found`에서 `x509: certificate signed by unknown
  authority`로 바뀜 — 이건 self-signed 인증서라면 당연히 나오는, 신뢰 체인
  문제이지 형식 문제가 아님(진짜 CA 인증서를 받거나, self-signed CA를
  클러스터 신뢰 번들에 직접 넣기 전까진 해결 안 됨 — 데모 랩 용도로는 이
  단계까지는 과함). **교훈**: 급하게 self-signed 인증서를 만들 때
  `openssl req -x509` 기본 동작을 믿지 말고, 반드시 `basicConstraints=
  CA:FALSE`와 `extendedKeyUsage=serverAuth`를 명시할 것 — 안 그러면
  "인증서가 있는데도 서버 인증서로 인식 안 되는" 헷갈리는 실패로 이어진다.
