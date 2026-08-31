# Solnari 보안 정책

Solnari는 credential과 private database topology를 다루는 desktop application입니다. 보안
문제는 공개 issue보다 비공개 경로로 먼저 알려 주세요.

## 취약점 제보

[GitHub의 비공개 보안 권고 작성 화면](https://github.com/dreamyoungs/solnari/security/advisories/new)을
사용해 주세요. 해당 기능을 사용할 수 없다면 공개 issue에는 재현 가능한 최소 설명만 남기고,
credential·token·private hostname·project/cluster/database 식별자·운영 SQL·schema·result를
첨부하지 마세요.

제보에는 가능한 범위에서 다음 정보를 포함해 주세요.

- 영향을 받는 commit 또는 app version
- macOS와 Swift/Xcode version
- 영향을 받는 연결 방법과 database engine
- 비밀정보를 제거한 재현 단계
- 예상되는 영향과 이미 확인한 완화 방법

## 지원 범위

아직 서명·notarization된 정식 Release가 없으므로 현재는 `main` branch의 최신 commit만
보안 수정 대상입니다. 첫 Release 이후 이 문서에 지원 version 범위를 명시합니다.

## 현재 구현된 경계

- 일반 database password는 macOS Keychain generic-password item에 저장합니다.
- 민감한 connection profile payload는 iCloud 동기화를 끈
  `WhenUnlockedThisDeviceOnly` Keychain item에 저장합니다.
- credential을 helper process argument로 전달하지 않습니다.
- Cloud SQL 자동 IAM 인증에서는 database password를 저장하거나 전달하지 않습니다.
- Cloud SQL Proxy, SSH와 Kubernetes port-forward는 임의 loopback port를 사용합니다.
- 연결 transport를 사용자가 명시적으로 선택하며 실패 시 다른 경로로 자동 fallback하지 않습니다.
- 앱 종료·화면 잠금·절전·사용자 session 전환 시 열린 DB session과 helper process를 정리합니다.
- 읽기 전용 profile은 보수적인 SQL 사전 검사와 database별 session 쓰기 차단을 함께 적용합니다.
- Codex UI는 현재 local prototype이며 prompt, SQL, schema와 result를 외부 App Server에 보내지 않습니다.

## 현재 한계

- 현재 Kubernetes 기능은 임시 relay Pod를 생성·삭제하므로 최소 `pods/portforward`보다
  넓은 권한이 필요합니다. 조직 관리형 또는 security-compliant transport로 간주하지 마세요.
- 강제 종료 뒤 orphan process 탐지, session idle/max timeout과 parent-death supervision은
  아직 완성되지 않았습니다.
- 현재 SQL 사전 검사는 의도적으로 보수적인 lexer이며 완전한 dialect parser가 아닙니다.
  공통 query timeout/cancel과 production write approval은 아직 강제되지 않습니다.
- app은 개발용 ad-hoc 서명을 사용하며 아직 Developer ID notarization 배포물이 아닙니다.
  Data Protection Keychain 전환도 필요한 signing entitlement와 함께 배포 단계에서 적용합니다.

## 공개 저장소 원칙

- 실제 조직의 project ID, cluster, namespace, service account, domain, IP와 database 이름을
  source, test fixture, screenshot 또는 sample profile에 포함하지 않습니다.
- password, token, DSN, authorization header, SQL 원문, schema와 result를 log, telemetry,
  crash report 또는 test failure output에 기록하지 않습니다.
- shell command 문자열이나 `sh -c`에 사용자 입력을 보간하지 않습니다.
- client UI 검증을 실제 IAM, Kubernetes RBAC, network policy와 database role의 대체물로
  취급하지 않습니다.

세부 신뢰 경계와 구현 우선순위는 [위협 모델](docs/threat-model.ko.md)과
[보안 우선 연결 아키텍처](docs/security-first-connection-architecture.ko.md)를 참고해 주세요.
