<p align="right"><a href="README.en.md">English</a></p>

# Solnari · 솔나리

**내가 매일 사용할 수 있도록 만들고 있는 macOS 네이티브 오픈소스 데이터베이스 도구입니다.**

솔나리는 DataGrip 1년 약정이 끝난 뒤, 개인적으로 계속 사용할 데이터베이스 도구가
필요해서 시작한 프로젝트입니다. 직접 만들기 시작하고 나서야 기존 제품의 완성도가 왜
높은지 더 잘 알게 되었고, 단순한 복제품이 아니라 macOS에 자연스럽고 오래 사용할 수
있는 오픈소스 데이터베이스 workspace로 발전시키고 있습니다.

로컬 데이터베이스를 편하게 다루는 것부터 시작하지만, Cloud SQL·SSH·Kubernetes 같은
private 연결 경로와 사람·Agent 사이의 실행 경계를 명확하게 만드는 것도 솔나리의 중요한
설계 방향입니다.

> [!IMPORTANT]
> 솔나리는 현재 활발히 개발 중인 초기 버전입니다. 아래의 **현재 지원**과 **구현 중인
> 방향**을 구분해서 확인해 주세요. 아직 보안 정책 엔진이나 DataGrip 수준의 전체 기능을
> 제공한다고 주장하지 않습니다.

## 왜 만들었나요?

처음에는 익숙하게 사용하던 DB 도구의 구독이 끝난 것이 계기였습니다. 쿼리를 작성하고,
테이블을 살펴보고, 결과를 여러 형식으로 복사하는 일상적인 흐름을 제 Mac에 맞게 직접
만들어 보고 싶었습니다.

연결 방식과 결과 타입, 시간대, 문자셋, 터널 수명주기까지 하나씩 구현하면서 DB 도구가
생각보다 훨씬 깊은 제품이라는 점을 체감했습니다. 그래서 솔나리의 목표도 "기능을 빠르게
흉내 내는 대체품"에서 다음과 같은 제품으로 바뀌었습니다.

- 일상적인 DB 작업에 실제로 사용할 수 있는 도구
- 로컬·클라우드·private database 연결 과정을 숨기지 않는 도구
- 비밀정보와 세션 수명주기를 신중하게 다루는 도구
- Agent가 SQL을 제안하더라도 실행 결정은 사람에게 남기는 도구

## 현재 지원

- PostgreSQL, MySQL, SQLite 연결 테스트와 실제 세션 연결
- 사용자 스키마·테이블·뷰 탐색과 동적 쿼리 실행
- Direct TCP, Google Cloud SQL Auth Proxy, SSH tunnel, Kubernetes 기존 리소스·임시 relay 경로
- ADC 기반 Cloud SQL 자동 IAM 인증, 엔진별 IAM DB 사용자명 제안, 프로젝트 리소스 조회
- 저장된 연결의 편집·재연결과 확인 절차가 있는 삭제
- 민감 연결 profile과 비밀번호의 device-only macOS Keychain 저장, opaque local index
- 다중 탭 SQL editor와 크기 조절 가능한 editor/result layout
- 컬럼 크기 조절과 다중 행 선택을 지원하는 AppKit 기반 결과 grid
- CSV, TSV, JSON, JSON Lines, Markdown, SQL `INSERT` 복사·내보내기
- PostgreSQL/MySQL/SQLite의 문자셋·정렬 규칙 설정 UI
- 절대 시간과 시간대 없는 값을 구분하는 결과 시간대 표시
- 한국어·영어 런타임 전환과 macOS light/dark appearance
- 앱 중복 실행 방지와 종료·잠금·절전·사용자 전환 시 연결 세션 정리
- 읽기 전용 profile의 보수적인 SQL 사전 검사와 DB session 쓰기 차단
- Agent 제안 SQL을 editor로 명시적으로 넘기는 Codex UI prototype

### 연결 지원표

| 데이터베이스 | Direct | Cloud SQL | SSH | Kubernetes |
| --- | --- | --- | --- | --- |
| PostgreSQL | 지원 | 지원 | 지원 | 기존 리소스 · 임시 relay |
| MySQL | 지원 | 지원 | 지원 | 기존 리소스 · 임시 relay |
| SQLite | 파일 연결 | 해당 없음 | 해당 없음 | 해당 없음 |

Kubernetes는 기존 Service/Pod에 `pods/portforward` 최소 권한으로 연결하는 경로를
우선 제공합니다. 임시 relay는 명시적으로 선택하는 실험 기능이며, 이 경우에만 세션용
Pod 생성·삭제 권한이 추가로 필요합니다.

## 솔나리가 지향하는 방향

솔나리는 범용 DB 사용성을 유지하면서, 필요한 조직에서는 승인된 연결 대상과 실행
정책을 강제할 수 있는 구조를 지향합니다.

1. **명시적인 private 연결**
   어떤 project, cluster, namespace, proxy와 database를 거치는지 사용자가 확인할 수
   있어야 하며, private 경로가 실패했을 때 public/direct 경로로 자동 전환하지 않습니다.
2. **짧게 존재하는 안전한 세션**
   tunnel, database connection과 단기 credential은 앱 종료·화면 잠금·절전·timeout에
   맞춰 정리되어야 합니다.
3. **조직이 검증할 수 있는 정책**
   연결 방법, 보안 정책과 DB 접근 등급을 분리하고, 조직 profile이 대상과 허용 범위를
   읽기 전용으로 고정할 수 있도록 설계합니다.
4. **사람이 통제하는 Agent 실행**
   Agent는 SQL을 설명하고 제안할 수 있지만 자동 실행하지 않습니다. 최종 SQL과 대상,
   예상 영향을 사람이 확인하고 명시적으로 승인해야 합니다.
5. **데이터를 수집하지 않는 desktop workflow**
   credential, SQL, schema, query result와 Agent 대화를 application log나 telemetry에
   기록하지 않습니다.

자세한 현재 구조와 보안 목표는 [Backend architecture](docs/backend-architecture.md),
[Connection paths](docs/connection-paths.md),
[보안 우선 연결 아키텍처](docs/security-first-connection-architecture.ko.md),
[위협 모델](docs/threat-model.ko.md)을 참고해 주세요.

## 아직 구현 중입니다

- 조직 관리형 policy profile과 서명·무결성 검증
- 연결 idle/max lifetime, 강제 종료 뒤 orphan process 복구
- dialect-aware SQL parser, 공통 timeout, query cancel과 결과/export 상한
- 운영 DML/DDL 승인과 일회성 write capability
- 실제 Codex App Server 및 정책에 제한된 MCP capability
- Developer ID 서명, notarization과 GitHub Release 자동 배포
- 테이블 데이터 보기·수정과 더 넓은 DB 객체 탐색

진행 중인 항목을 현재 보장처럼 표시하지 않는 것을 프로젝트 문서 원칙으로 삼습니다.

## 설치

GitHub Release에서 내려받을 수 있는 서명·notarization된 앱은 아직 준비 중입니다. 현재는
소스에서 개발용 앱을 빌드할 수 있습니다.

### 요구사항

- macOS 14 이상
- Swift 6.1 이상 또는 호환되는 Xcode toolchain

선택한 연결 경로에 따라 `cloud-sql-proxy`, OpenSSH 또는 `kubectl`이 필요합니다. Cloud SQL
프로젝트 리소스 조회에는 ADC access token을 발급하는 Google Cloud CLI(`gcloud`)가 필요합니다.

### 빌드하고 실행하기

```bash
git clone https://github.com/dreamyoungs/solnari.git
cd solnari
./Scripts/run-app.sh
```

Release 설정의 로컬 앱을 만들려면 다음을 실행합니다.

```bash
./Scripts/build-app.sh release
open .build/app/release/Solnari.app
```

이 앱은 [솔나리 꽃 아이콘](Sources/Solnari/Resources/SolnariIcon.png)과 로컬 개발용 ad-hoc
서명을 사용합니다. 공개 Release에는 Developer ID 서명과
Apple notarization을 별도로 적용할 예정입니다.

빠른 개발 반복에는 `swift run Solnari`도 사용할 수 있습니다. 최초 번들 실행 시 이전
`swift run`에서 만든 비민감 연결 목록·언어·표시 시간대 설정을 한 번 이관하며, 기존
Keychain 비밀번호는 같은 opaque profile ID에 연결된 상태로 유지합니다.

## 검증

```bash
swift format lint --recursive --strict Sources Tests
swift test
./Scripts/build-app.sh release
git diff --check
```

PostgreSQL과 MySQL의 live integration test는 테스트 서버 환경변수가 있을 때만 실행됩니다.
SQLite와 격리된 fake CLI transport test는 기본 `swift test`에서 실행됩니다. 자세한 설정은
[Backend architecture](docs/backend-architecture.md)를 참고해 주세요.

## 개인정보와 보안

- 민감 connection profile과 일반 DB 비밀번호는 `UserDefaults`가 아니라 device-only
  macOS Keychain에 저장하고, local store에는 opaque UUID 순서만 둡니다.
- 자동 IAM 인증에서는 DB 비밀번호를 요청하거나 helper argument로 전달하지 않습니다.
- helper command는 shell 문자열이 아닌 executable과 argument 배열로 실행합니다.
- Codex 대화, SQL, schema와 result는 현재 Solnari가 영속화하거나 telemetry로 보내지 않습니다.
- private 연결 실패 시 다른 transport로 자동 fallback하지 않습니다.

현재 한계와 취약점 제보 방법은 [SECURITY.md](SECURITY.md)를 확인해 주세요. 실제 endpoint,
credential, 운영 SQL 또는 고객 데이터를 공개 issue에 첨부하지 마세요.

## 기여하기

작은 버그 수정, DB별 동작 검증, UX 제안과 보안 리뷰를 모두 환영합니다.
[CONTRIBUTING.md](CONTRIBUTING.md)의 개발 및 검증 절차를 먼저 확인해 주세요.

## 라이선스

Solnari는 [Apache License 2.0](LICENSE)으로 공개됩니다.
