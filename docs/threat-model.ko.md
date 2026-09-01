# Solnari 위협 모델

> 상태: 구현과 함께 갱신되는 초안
> 범위: macOS desktop app, database driver, local helper process, provider credential과 향후 Agent/MCP 경계

## 보호할 자산

- database password, OAuth/IAM token, SSH/TLS secret와 kube credential
- private hostname, project, cluster, namespace, database와 사용자 identity의 연결 관계
- SQL, schema, sample data, query result와 export
- 사용자가 선택한 target, access level과 승인 기록
- Solnari가 시작한 tunnel, database connection과 in-memory Agent session

## 신뢰 경계

```text
사용자
  → Solnari UI와 policy engine
  → local AES-GCM vault / provider credential store
  → bundled Node core / local helper process (ssh, kubectl)
  → private 또는 local network path
  → database role

향후 Agent
  → 제한된 Solnari MCP capability
  → 동일한 policy와 approval 검증
  → 위의 session 경계
```

Solnari의 UI는 실수 방지 계층입니다. 최종 권한은 provider IAM, Kubernetes RBAC, network
policy와 database role이 강제해야 합니다. 현재 local vault는 평문 노출 방지 계층이며 동일
사용자 권한을 탈취한 process에 대한 system credential store 수준의 격리를 제공하지 않습니다.

## 고려하는 공격과 실수

- profile 또는 UI 입력을 바꾸어 승인되지 않은 운영 target으로 접속
- private transport 실패를 public/direct 연결로 우회
- process argument, log, crash report, clipboard와 Agent context를 통한 credential 유출
- 악성 또는 바뀐 Kubernetes resource로의 target drift
- 앱 종료·crash 뒤 남은 tunnel과 listening port
- read-only로 표시된 session에서 DML/DDL 실행
- Agent가 제안과 실행 경계를 우회하거나 approval을 재사용
- 개발 identity, production identity와 최근 연결 정보의 혼동
- 공개 sample, screenshot 또는 test fixture를 통한 실제 조직 정보 노출

## 기본 보안 불변식

1. 인증할 수 없는 principal과 검증할 수 없는 target은 추측해 계속하지 않습니다.
2. private 경로 실패 시 public IP, Direct TCP 또는 다른 kube context로 fallback하지 않습니다.
3. local tunnel은 `127.0.0.1`에만 열고 Solnari가 시작한 process만 종료합니다.
4. 장기 provider key를 만들거나 복제하지 않으며 단기 token은 가능한 한 memory에만 둡니다.
5. credential, SQL, schema, result와 Agent 대화를 log나 telemetry에 기록하지 않습니다.
6. Agent가 생성한 SQL은 명시적인 editor handoff와 사람의 실행 결정을 거칩니다.
7. 관리형 profile의 target과 정책은 local UI에서 수정해 우회할 수 없어야 합니다.
8. read-only와 production 제한은 UI뿐 아니라 session 설정과 실제 DB role로 강제합니다.

## 현재 보장과 차이

현재 구현은 local connection profile과 AES-GCM credential vault, 자동 IAM의 password 비사용,
명시적 transport 선택, loopback tunnel, 정상 종료·잠금·절전 cleanup과 Agent의 명시적 editor
handoff를 제공합니다. 자동 잠금 해제를 위한 encryption key도 같은 사용자 영역에 있으므로,
동일 사용자 권한을 탈취한 process에 대한 Keychain 수준의 보호는 제공하지 않습니다.
읽기 전용 profile은 보수적인 SQL 사전 검사와 database session 쓰기 차단을 함께 사용합니다.

아직 다음 경계는 완성되지 않았습니다.

- 기존 Kubernetes resource identity 검증과 최소 RBAC transport
- crash orphan recovery와 session timeout
- dialect-aware SQL parser, 공통 query timeout/cancel과 production approval
- server-side authorization을 수행하는 MCP capability
- signing/notarization된 배포물과 update 신뢰 경계

README와 UI는 위 항목을 현재 구현된 보장으로 표시해서는 안 됩니다.

## 명시적인 non-goals

- 초기 version에서 Kubernetes resource provisioner 또는 cluster administrator가 되지 않습니다.
- DataGrip을 포함한 상용 DB 도구의 모든 기능을 한 번에 복제하지 않습니다.
- 자체 Zero Trust control plane, 사용자 directory 또는 migration orchestrator를 먼저 만들지 않습니다.
- Agent 자율성을 이유로 사용자 승인이나 실제 infrastructure 권한을 우회하지 않습니다.
- SQL과 query result를 수집하는 SaaS telemetry를 만들지 않습니다.

## 검증 전략

보안 기능은 UI snapshot만으로 완료 처리하지 않습니다. 각 경계에는 가능한 한 다음 형태의
실패 테스트를 추가합니다.

- 잘못된 target·identity·policy 입력의 fail-closed 거부
- loopback 이외 interface binding 부재
- child process 종료와 local port 회수
- app crash 뒤 orphan 식별과 안전한 정리
- read-only session의 실제 DML/DDL 거부
- timeout과 cancel의 server 반영
- log/test output에서 credential·SQL·result 부재
- 변조되거나 만료된 Agent session/approval의 server-side 거부

구체적인 단계와 관리형 연결 설계는
[보안 우선 연결 아키텍처](security-first-connection-architecture.ko.md)를 따릅니다.
