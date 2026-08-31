# Solnari 보안 우선 연결 아키텍처 제안

> 상태: 메인 구현 스레드 전달용 설계 초안
> 목적: 일반적인 DB 도구의 연결 편의성을 유지하면서, 조직 환경에서는 강력한 보안 정책을 제품의 핵심 차별점으로 제공한다.

## 1. 제품 방향

Solnari는 로컬 개발자부터 엄격한 조직 보안 환경까지 사용할 수 있는 범용 DB 도구를
지향한다. 보안 요구사항을 모든 연결에 일률적으로 강제해 사용성을 잃거나, 반대로 UI
경고에만 의존해 운영 DB를 위험하게 다루지 않는다.

핵심 컨셉은 다음과 같다.

> **Security-first database client for humans and agents**

- 일반 사용자는 Direct, SSH, Cloud SQL, Kubernetes, SQLite 연결을 쉽게 사용할 수 있다.
- 조직은 승인된 연결 대상과 정책을 배포하고 사용자가 임의로 우회하지 못하게 할 수 있다.
- Codex는 credential을 취급하거나 임의 실행하는 주체가 아니라, 정형화된 진단 결과를
  이해하기 쉽게 설명하는 연결 서포터로 동작한다.
- 클라이언트 검증은 실수 방지 장치이며, 실제 권한은 GCP IAM, Kubernetes RBAC,
  NetworkPolicy, PostgreSQL role에서 강제한다.

## 2. 연결 방법, 보안 정책, 접근 등급의 분리

연결 방법과 보안 수준을 하나의 열거형으로 섞지 않는다. 세 축을 독립적으로 모델링하고
정책이 허용 가능한 조합을 결정한다.

### Connection Method

- `sqliteFile`: 로컬 SQLite 파일
- `direct`: PostgreSQL/MySQL 호스트와 포트에 직접 연결
- `sshTunnel`: 기존 SSH bastion을 통한 포트 포워딩
- `cloudSQLProxy`: 사용자의 ADC를 사용하는 로컬 Cloud SQL Auth Proxy
- `kubernetesPortForward`: 기존 Service/Pod에 port-forward
- `managedGKEProxy`: 조직이 승인한 전용 `admin-db-proxy`에 검증 후 port-forward
- `temporaryRelay`: 임시 relay Pod 생성. 개발·실험용 고급 기능이며 조직 정책으로 금지 가능

### Security Policy

- `localDevelopment`
  - loopback과 로컬 파일 중심
  - 개발 편의 기능 허용
  - 비TLS가 필요하면 loopback에 한정하고 명시적으로 경고
- `standard`
  - TLS 인증서 검증
  - Keychain credential
  - SSH, Cloud SQL Proxy, 기존 Kubernetes 리소스 연결
  - 기본 timeout과 credential 비기록
- `organizationManaged`
  - 조직이 배포한 변경 불가능한 대상 정의 사용
  - project, cluster, namespace, proxy identity, image digest 검증
  - 단기 사용자 인증과 fail-closed 동작
  - 공개 IP 또는 Direct 연결로 fallback 금지
  - 운영 환경 승인 절차와 감사 metadata 강제

### Access Level

- `readOnly`
- `readWrite`
- `migration`

화면과 세션에는 항상 세 값이 함께 표시되어야 한다. 예:

```text
운영 주문 DB · Managed GKE · Read-only
개발 로컬 DB · Direct · Read-write
```

## 3. 기본 지원 매트릭스

| 사용 사례 | 권장 연결 | 기본 정책 |
| --- | --- | --- |
| 로컬 SQLite | SQLite File | Local Development |
| 로컬 PostgreSQL/MySQL | Direct | Local Development |
| VPN/사내망 DB | Direct + TLS | Standard |
| Bastion 뒤의 DB | SSH Tunnel | Standard |
| 소규모 팀의 Cloud SQL | 로컬 Cloud SQL Auth Proxy | Standard |
| 기존 Kubernetes DB/relay | Existing Resource Port Forward | Standard |
| 엄격한 조직 운영 DB | Managed GKE admin-db-proxy | Organization Managed |
| 임시 개발 진단 | Temporary Relay | Local/Standard의 명시적 고급 옵션 |

Direct 연결 자체를 낮은 보안으로 간주하지 않는다. 네트워크 경계, TLS, 인증 방식에 따라
VPN 내부 DB나 사내 관리형 DB에서도 정상적인 선택이 될 수 있다.

## 4. 조직 관리형 GKE 연결

조직 운영 환경의 목표 경로는 다음으로 고정한다.

```text
Solnari
  → 사용자 단기 GKE 인증
  → GKE API
  → Kubernetes port-forward
  → 전용 admin-db-proxy
  → Cloud SQL private IP
```

### 반드시 지켜야 하는 경계

- Solnari는 운영 Cloud SQL 공개 IP에 직접 접속하지 않는다.
- `admin-db-proxy`는 애플리케이션 트래픽과 공유하지 않는다.
- 개발과 운영은 project, cluster, namespace, Proxy, KSA/GSA, DB user, profile을 분리한다.
- Solnari 사용자는 승인된 namespace에서 리소스 조회와 `pods/portforward` 권한만 가진다.
- Pod/Service/Secret 생성·수정·삭제, `exec`, `logs`, Secret 조회, cluster-admin을 요구하지 않는다.
- `admin-db-proxy`는 LoadBalancer, NodePort, Ingress로 외부 공개하지 않는다.
- 조직 관리형 경로에서는 임시 relay Pod를 만들지 않는다.
- private 경로 실패 시 Direct TCP나 공개 IP로 fallback하지 않는다.

### Service와 Pod 처리

일반 사용자에게 Service/Pod를 직접 선택하게 하지 않는다. 사용자는 조직이 제공한 연결
프로필을 선택하고 Solnari가 내부적으로 다음을 수행한다.

1. 승인된 ClusterIP Service 조회
2. Service가 외부에 노출되지 않았는지 검사
3. selector와 EndpointSlice에서 실제 Pod 후보 확인
4. Pod의 UID, label, KSA, image digest, security context 검증
5. 검증된 정확한 Pod에 `127.0.0.1` port-forward
6. 재연결 시 새 Pod를 자동 신뢰하지 않고 전체 검증 반복

Service는 안정적인 논리적 이름으로 사용하되, 실제 연결은 검증된 Pod identity에
귀속한다. 연결 중 Pod가 종료되면 세션을 닫고 새 대상에 대해 다시 인증·검증한다.

## 5. 조직 제공 연결 정의

플랫폼팀은 비밀정보가 없는 연결 정의를 제공할 수 있다. 초기에는 로컬 YAML/JSON을
지원하고, 향후 서명된 중앙 배포 정책을 고려한다.

```yaml
apiVersion: solnari.dev/v1alpha1
kind: ManagedConnection

metadata:
  name: production-orders-readonly
  displayName: 운영 주문 DB 읽기 전용

spec:
  environment: production
  securityPolicy: organizationManaged
  accessLevel: readOnly

  gcp:
    project: company-production
    cluster: production-gke
    location: asia-northeast3

  kubernetes:
    namespace: admin-db-proxy-prod
    service: admin-db-proxy
    expectedServiceAccount: admin-db-proxy-prod
    expectedImage: gcr.io/cloud-sql-connectors/cloud-sql-proxy@sha256:...
    remotePort: 5432

  database:
    engine: postgresql
    instanceConnectionName: company-production:asia-northeast3:orders
    name: orders
    authentication: userIAM
```

이 정의에는 다음을 넣지 않는다.

- password
- access token 또는 IAM DB login token
- service-account key
- kubeconfig credential
- 개인키
- DSN

조직 관리형 프로필의 대상 필드는 UI에서 읽기 전용이어야 한다. 로컬 사용자가 내용을
수정하면 더 이상 관리형 프로필로 신뢰하지 않는다.

## 6. 인증과 credential 처리

### 인증 분리

- GKE 터널 인증: 현재 사용자의 ADC 또는 gcloud 단기 인증
- Cloud SQL 인스턴스 연결: Proxy 전용 KSA/GSA와 Workload Identity
- PostgreSQL 인증: 사용자별 IAM DB user 또는 승인된 IAM DB group

모든 사용자가 Proxy GSA 하나의 PostgreSQL identity로 접속하지 않도록 주의한다.
Proxy가 자신의 GSA로 `--auto-iam-authn`을 수행하면 사용자별 DB 감사 요구와 충돌할 수
있다. Proxy의 인스턴스 연결 identity와 실제 PostgreSQL 사용자 identity를 분리하고,
Solnari 사용자의 단기 IAM DB login token을 DB 드라이버에 메모리로 전달하는 방식을
우선 검토한다.

### 저장과 전달 규칙

- 정적 GSA key, access token, 장기 kubeconfig를 Solnari가 저장하지 않는다.
- 일반 DB password가 불가피한 경우 macOS Keychain만 사용한다.
- 단기 token은 Keychain에도 저장하지 않고 세션 메모리에서만 보유한다.
- token/password를 subprocess command-line argument로 전달하지 않는다.
- credential 환경 변수 사용을 피하고, 불가피하면 해당 child에만 전달하고 즉시 폐기한다.
- UserDefaults, 설정 파일, 로그, crash report, telemetry, clipboard에 credential을 기록하지 않는다.
- 앱은 기존 사용자 kubeconfig를 복사하거나 장기 보관하지 않는다. 필요하다면 임시
  kubeconfig를 세션 디렉터리에 만들고 종료 시 삭제하는 방식을 검토한다.

## 7. 연결 서포터

연결 서포터는 사용자가 Kubernetes 보안 구조를 이해하지 않아도 올바른 경로를 선택하게
돕는다.

### 첫 질문

```text
데이터베이스는 어디에서 접근할 수 있나요?

1. 이 Mac에서 바로 접근 가능
2. Google Cloud SQL
3. Bastion 서버를 통해서만 가능
4. Kubernetes 내부에서만 가능
5. 조직에서 받은 연결 프로필이 있음
6. 잘 모르겠음
```

### 책임 분리

일반 프로그램 코드가 읽기 전용으로 환경을 검사하고 정형화된 결과를 만든다. Codex는
이 결과를 쉬운 말로 설명하고 다음 행동을 제안한다.

Codex가 직접 받아서는 안 되는 정보:

- token/password/private key
- provider의 필터링되지 않은 원문 응답
- 사용자가 승인하지 않은 schema, SQL, query result

Codex가 수행하면 안 되는 행동:

- 임의의 Kubernetes 리소스 생성
- 자동 권한 상승
- authorized network 또는 공개 IP 활성화
- 사용자의 확인 없는 SQL 실행
- 보안 검증 실패 우회

### 관리형 연결 사전 검사 예시

- 현재 gcloud account와 예상 사용자/group
- project, cluster, location, namespace
- 최소 RBAC 및 불필요한 권한 부재
- Service 유형, EndpointSlice, 실제 Pod UID
- image exact version/digest
- KSA, security context, NetworkPolicy 존재 여부
- DB name, 현재 IAM DB user, access level

화면에는 원본 명령보다 의미를 우선해 표시한다.

```text
현재 developer@example.com 계정으로 운영 환경에 연결하려고 합니다.
대상은 승인된 admin-db-proxy이며 외부 공개 설정은 없습니다.
현재 권한은 조회와 port-forward뿐입니다.
DB 접근 등급은 읽기 전용입니다.
```

## 8. 안전한 세션 생명주기

연결은 명시적인 상태 머신으로 관리한다.

```text
idle
 → validatingTarget
 → authenticatingTunnel
 → openingTunnel
 → authenticatingDatabase
 → validatingDatabaseIdentity
 → connected
 → closing
 → closed
```

런타임 세션에는 다음만 메모리로 유지한다.

- 검증된 target identity와 Pod UID
- loopback local port
- Solnari가 시작한 tunnel PID
- process 시작 시각과 소유권 nonce
- 단기 DB token
- idle timeout과 maximum session deadline
- 실제 DB user/database/access level

### 종료 조건

- 사용자 연결 종료
- 앱 정상 종료
- Mac sleep
- 사용자 전환 또는 화면 잠금 정책
- idle timeout
- 최대 세션 시간 초과
- 인증 만료
- port-forward 또는 DB 연결 실패
- 대상 Pod 교체
- 사용자 query 취소 시 필요한 local connection 정리

### orphan 방지

앱이 `kill -9`로 종료되면 앱 내부 cleanup은 실행될 수 없다. 따라서 macOS에서는 다음을
조합한다.

- 부모 PID를 감시하는 최소 권한 tunnel supervisor
- 프로세스 그룹 단위 종료
- 다음 앱 실행 시 소유권 metadata를 이용한 orphan 복구
- PID뿐 아니라 executable, 시작 시각, session nonce가 모두 일치할 때만 종료
- Solnari가 시작하지 않은 kubectl/SSH/Proxy 프로세스는 절대 종료하지 않음

모든 포트는 사용 가능한 loopback 포트에 `127.0.0.1`로만 bind한다. `0.0.0.0`은
금지한다.

## 9. SQL 실행 안전 정책

UI 차단과 서버 권한을 함께 사용한다.

### Read-only 프로필

- PostgreSQL 세션/transaction을 실제 `READ ONLY`로 설정
- read-only IAM DB user와 PostgreSQL role 사용
- `INSERT`, `UPDATE`, `DELETE`, DDL, `COPY`, `CALL`, `DO`, `VACUUM` 등 변경 가능 SQL 차단
- 다중 statement와 transaction 밖 실행을 명확히 표시
- `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` 적용
- 최대 결과 row 수, cell 크기, export 크기 제한
- 대량 조회와 `SELECT *` 경고 및 `LIMIT` 권장

단순 문자열 prefix 검사만으로 보안을 구현하지 않는다. SQL parser 기반 분류를 사용하되,
실제 권한 통제는 PostgreSQL role과 read-only transaction이 담당한다.

### 운영 변경

`readWrite`와 `migration`은 별도 프로필로 분리하고 다음을 확인한다.

- 전체 SQL
- project/environment/database
- 실제 IAM DB user
- 예상 영향 row 수 또는 사전 EXPLAIN 정보
- access level
- 별도 사용자 확인

Agent가 생성한 SQL은 자동 실행하지 않는다. 항상 editor handoff 후 사용자가 검토하고
실행한다.

## 10. 감사, 개인정보, 로깅

### 인프라 감사

- GKE Audit Log에서 실제 사용자 identity의 port-forward를 추적할 수 있어야 한다.
- PostgreSQL에서는 사용자별 IAM DB identity로 연결을 구분한다.
- 개발과 운영의 identity 및 프로필을 공유하지 않는다.

### Solnari 감사 metadata

허용 가능한 최소 metadata:

- 사용자 식별자
- environment와 database 식별자
- connection 시작/종료
- query classification
- 성공/실패 및 정제된 오류 코드

기록하지 않는 정보:

- SQL 원문
- schema 원문
- query result와 sample data
- 개인정보
- password/token/DSN
- provider 응답 원문

SQL, schema, 결과를 Codex나 외부 LLM에 자동 전송하지 않는다. 사용자가 전달할 범위를
선택하고 전송 내용을 사전에 확인할 수 있어야 한다.

## 11. 실패 안전성

다음이 예상값과 다르면 연결을 중단한다.

- account 또는 IAM user/group
- project, cluster, location, namespace
- Service, Pod UID, label, KSA, image digest
- database와 access level
- 실제 PostgreSQL current user

추가 원칙:

- Proxy 인증 또는 private 경로 실패 시 공개 경로로 fallback하지 않는다.
- authorized network와 공개 IP를 자동 생성·활성화하지 않는다.
- 운영 DB 권한 검증이 불완전하면 query를 실행하지 않는다.
- 관리형 정책에서 TLS 검증을 끄는 옵션을 제공하지 않는다.
- 사용자 오류 메시지에는 credential, DSN, SQL 결과, provider 응답 원문을 포함하지 않는다.
- 재연결 때 이전 세션을 무조건 재사용하지 않고 인증과 target을 다시 검사한다.

## 12. 앱과 인프라의 책임 경계

### Solnari가 구현할 항목

- 연결 방법/보안 정책/접근 등급 모델
- 관리형 연결 정의 로드 및 검증
- gcloud/GKE 사용자 identity 사전 검사
- Service/EndpointSlice/Pod identity 검사
- 안전한 loopback port-forward
- 단기 IAM DB token의 메모리 처리
- tunnel supervisor와 세션 timeout
- read-only 세션, SQL 분류, 승인 UI
- 민감정보 없는 감사 metadata
- fail-closed 오류 처리

### 플랫폼팀이 제공할 항목

- 전용 admin-db-proxy Deployment/ClusterIP Service
- exact image version과 digest
- non-root, read-only root filesystem, no privilege escalation, capability drop
- resource request/limit
- 전용 KSA/GSA와 Workload Identity
- 최소 Cloud SQL Client IAM
- 최소 Kubernetes RBAC
- NetworkPolicy와 필요한 Google API/private IP egress
- Cloud SQL private IP
- 사용자별 IAM DB user/group
- PostgreSQL read-only/read-write/migration role
- GKE Audit Log

Solnari는 이 인프라를 임의로 생성하지 않고 검증 결과가 맞을 때만 연결한다.

## 13. 현재 구현에서의 전환 방향

기존 엔진/터널 분리 구조는 유지할 수 있다. 전면 재작성보다는 연결 계층의 중간 규모
재설계가 필요하다.

### 재사용 가능한 영역

- SwiftUI workspace와 결과 UI
- PostgreSQL/MySQL/SQLite engine adapter
- typed query result와 export
- 프로필 이름과 비밀정보 분리
- Keychain abstraction
- 포트 자동 할당과 loopback binding 기반
- 기존 Service/Pod에 리소스 생성 없이 port-forward하는 일반 Kubernetes 경로
- 보안 정책과 DB 접근 등급의 profile 저장 및 읽기 전용 session 차단

### 변경 또는 신규 구현 영역

- 단일 ConnectionProfile을 target definition과 runtime session으로 분리
- existing Kubernetes transport에 managed target 검증과 immutable policy 적용
- 관리형 정책에서는 임시 Pod 생성 경로 제거
- credential provider와 사용자별 IAM DB 인증
- target preflight 및 identity verifier
- 세션 상태 머신, idle/max duration, sleep/user-switch 대응
- parent-death supervisor와 orphan recovery
- access level, SQL parser/classifier, server-side read-only 적용
- 운영 연결 색상·경고·재확인
- 정제된 오류와 감사 metadata

임시 relay 기능을 오픈소스 범용 고급 옵션으로 유지할 수는 있지만 다음 조건이 필요하다.

- 기본 추천 경로가 아님
- 생성 리소스와 요구 권한을 명확히 표시
- 조직 정책으로 완전히 비활성화 가능
- organization-managed 또는 보안 준수 연결로 표시하지 않음

## 14. 권장 구현 단계

### Phase 1: 모델과 정책 경계

- `ConnectionMethod`, `SecurityPolicy`, `AccessLevel` 추가
- 저장 target과 메모리 runtime session 분리
- 기존 일반 연결의 동작 유지
- 조직 관리형 프로필에서 필드 잠금 및 fallback 금지

### Phase 2: Managed GKE transport

- 기존 Service/EndpointSlice/Pod 조회
- 최소 RBAC 사전 검사
- KSA/image digest/Pod UID 검증
- exact Pod loopback port-forward
- 임시 Pod 생성 없는 연결

### Phase 3: Identity와 lifecycle

- 사용자 gcloud/GKE identity 확인
- 사용자별 IAM DB token
- DB current user/database 검증
- idle/max timeout, sleep/user-switch 종료
- supervisor와 orphan recovery

### Phase 4: SQL safety

- access level별 세션 설정
- parser 기반 query classification
- read-only transaction과 DB role 검증
- 운영 변경 승인 화면
- query cancel과 결과/export 한도

### Phase 5: 감사 및 보안 검증

- 민감정보 없는 metadata 감사
- 로그/crash/telemetry redaction 검증
- 강제 종료 및 장애 시나리오 테스트
- 개발 identity와 운영 identity 분리 검증

## 15. 필수 검증 시나리오

- tunnel이 `127.0.0.1`에만 bind됨
- 정적 credential 없이 연결됨
- 허용되지 않은 사용자/namespace에서 port-forward가 거부됨
- Solnari 사용자가 Pod 생성·삭제, Secret 조회, exec, logs 권한을 가지지 않음
- 개발 identity로 운영 Proxy/DB에 접속할 수 없음
- Service가 외부 공개되지 않았고 Pod identity/digest가 예상값과 일치함
- Pod 교체 뒤 identity 재검증 없이는 재연결되지 않음
- 사용자별 IAM DB identity가 PostgreSQL에서 구분됨
- read-only 프로필에서 DML/DDL이 UI와 실제 DB 권한 모두에서 거부됨
- 앱 정상 종료, sleep, 사용자 전환 뒤 tunnel/token이 남지 않음
- 앱 강제 종료 뒤 supervisor 또는 다음 실행 복구로 orphan이 남지 않음
- private IP 경로 장애 시 공개 IP로 fallback하지 않음
- 로그, crash report, telemetry에 SQL/result/schema/credential이 포함되지 않음
- Agent SQL이 사용자 확인 없이 자동 실행되지 않음

## 16. 남은 제품 결정

- 조직 연결 정의의 배포 방식: 파일, Git, MDM, 서명된 registry
- 관리형 프로필 무결성 검증 및 서명 방식
- 일반 Kubernetes existing-resource 모드에서 허용할 리소스 범위
- 임시 relay 기능의 기본 포함 여부 또는 별도 실험 기능 처리
- gcloud CLI 기반과 Google/GKE API native client의 단계적 전환 시점
- PostgreSQL SQL parser 선택
- 운영 변경 승인 UX와 조직별 승인 연동 범위
- 감사 metadata의 로컬 저장 여부와 조직 수집 연동 방식

## 17. 핵심 결정 요약

1. 보안을 Solnari의 주요 제품 컨셉으로 삼되 일반 연결 기능을 제거하지 않는다.
2. 연결 방법, 보안 정책, DB 접근 등급을 독립적으로 모델링한다.
3. 조직 운영 DB는 승인된 `admin-db-proxy`만 사용하고 임시 Pod를 만들지 않는다.
4. 사용자는 Service/Pod 세부사항이 아니라 조직 제공 연결 프로필을 선택한다.
5. Proxy의 GSA와 실제 PostgreSQL 사용자 IAM identity를 분리한다.
6. Codex는 credential을 보지 않으며 정제된 진단을 설명하는 연결 서포터 역할을 한다.
7. UI 차단과 함께 IAM/RBAC/NetworkPolicy/DB role로 실제 권한을 강제한다.
8. private 경로 실패는 fail closed이며 공개 경로 fallback을 제공하지 않는다.
9. 일반 Direct/SSH/Cloud SQL/Kubernetes/SQLite 사용자는 계속 지원한다.
10. 기존 UI와 엔진 구조는 재사용하고 연결·세션·정책 계층을 중심으로 재설계한다.
