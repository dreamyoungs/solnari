# 외부 Agent용 MCP 접근

Solnari는 로컬 Codex desktop app, CLI 또는 IDE extension이 앱에서 이미 연결한 database 중 대상을 지정해
연결 권한에 따라 조회·변경할 수 있는 STDIO MCP server를 제공합니다. 앱 내부 Codex SQL 어시스턴트와는
별개의 기능입니다.

OpenAI 공식 문서에 따르면 로컬 Codex client는 STDIO MCP server를 직접 실행할 수 있고,
desktop app·CLI·IDE extension은 같은 host의 MCP 설정을 공유합니다. ChatGPT web은 local Codex
설정을 읽지 않으므로 이 local server에 직접 연결되지 않습니다.

- [OpenAI: Model Context Protocol](https://developers.openai.com/codex/mcp/)

## 구조

```text
Codex desktop / CLI / IDE
  → bundled Node 24 STDIO MCP server
  → ~/Library/Application Support/Solnari/mcp.sock
  → running Solnari app
  → explicitly requested connected database session
```

MCP process는 database profile이나 credential vault를 직접 읽지 않습니다. Solnari app이 연결,
credential, transport와 database session을 계속 소유하고 MCP process는 사용자 전용 local
socket으로 정형화된 요청만 전달합니다.

## 활성화와 등록

1. 개발·운영 등 사용할 DB를 Solnari에서 연결합니다.
2. `설정 → MCP 접근 → Codex에 연결`을 누릅니다. 등록에 성공하면 로컬 MCP 접근도 켜집니다.
3. Codex를 재시작합니다.
4. `solnari_list_connections`로 연결된 DB 목록을 조회하고, 사용할 DB의 `connectionID`를 각 스키마·쿼리 도구에 전달합니다.

등록 버튼은 설치된 Codex 앱의 내장 실행 파일 또는 CLI로 `codex mcp add`를 실행합니다.
Node와 MCP 서버는 Solnari 앱에 포함되어 별도 설치가 필요 없습니다. Codex 설정의 다른 항목은
Codex의 공식 등록 명령이 보존합니다. 기존 `solnari` 등록은 현재 앱 경로로 갱신됩니다.
수동 등록을 원하면 로컬 MCP 접근을 켜고 기존 `Codex 등록 명령 복사`를 사용할 수 있습니다.

등록 명령은 설치된 app 내부의 bundled Node runtime과 MCP entrypoint를 절대 경로로 지정합니다.
비밀번호, token 또는 database 정보는 명령 인자나 환경 변수에 포함하지 않습니다.

## 제공 도구

| 도구 | 동작 |
| --- | --- |
| `solnari_status` | 실행 중인 Solnari MCP bridge 상태 확인 |
| `solnari_list_connections` | 현재 연결된 DB의 정제된 metadata와 session ID 목록 |
| `solnari_list_schema` | 지정한 연결의 table, view, materialized view와 function 목록 |
| `solnari_describe_object` | column, index, constraint, comment와 definition 조회 |
| `solnari_execute_read_query` | 읽기 전용 profile에서 단일 read query 실행 |
| `solnari_execute_query` | 쓰기 허용 profile에서 조회·변경 SQL 실행 |

읽기 도구는 MCP `readOnlyHint: true`를 사용합니다. `solnari_execute_query`는
`readOnlyHint: false`, `destructiveHint: true`, `idempotentHint: false`로 선언됩니다.
두 실행 도구 모두 Solnari에서 다음 조건을 검사합니다.

- MCP 접근이 켜져 있음
- Mac이 실제 시스템 절전으로 연결을 중단한 상태가 아님
- 요청한 session ID에 해당하는 profile이 이미 연결됨
- 해당 연결의 MCP 동시 실행 한도에 여유가 있음
- profile의 표시 권한과 실제 연결된 DB session의 권한이 도구의 요구 권한과 일치함

`solnari_execute_read_query`는 `Read-only` 연결에서 기존 SQL 사전 검사와 DB session의 쓰기
차단을 적용합니다. `solnari_execute_query`는 `Read / Write` 연결에서만 실행되며, 쓰기 허용
연결의 SELECT 조회에도 이 도구를 사용합니다. `Migration` 권한은 허용하지 않습니다.

스키마·객체 조회와 두 쿼리 실행 도구는 모두 `solnari_list_connections`에서 얻은 `connectionID`가
필수입니다. 앱의 화면 선택이나 다른 MCP 클라이언트의 요청은 실행 대상을 바꾸지 않습니다.
연결이 끊겼거나 DB 전환으로 session ID가 바뀌면 이전 ID는 거절합니다. MCP가 DB를 자동으로
연결하거나 다른 DB로 대체하지 않습니다.

MCP에는 전역 활성 연결이 없습니다. 연결된 개발·운영 DB를 동시에 사용할 수 있으므로 앱의
화면 선택을 바꾸거나 다른 연결을 끊을 필요가 없습니다. 목록에서 대상 이름·database를
확인한 뒤 각 요청의 ID만 지정합니다. AI에는 이 동작을 서버 지침과 각 도구 설명으로
안내하며, 혼동을 유발하는 기존 `solnari_get_active_connection` 도구는 공개 목록에서 제거했습니다.
`solnari_status`는 `supportsMultipleConnections: true`, `requiresUISelection: false`와 앱 버전을
반환합니다. 이전 도구 설명이 남아 있으면 MCP 클라이언트를 재시작하고 등록 앱 경로를 확인하세요.

### 버전 확인

MCP 초기 연결 응답의 서버 버전과 `solnari_status` 도구 설명에는 MCP 서버의 배포 버전이
표시됩니다. 서버 버전은 backend 패키지 버전에서 가져오며 앱 배포 시 함께 갱신됩니다.
앱 bridge 요청의 성공·실패 응답에는 `mcpServerVersion`을 포함하고, 텍스트 응답에도 버전을 표시합니다.
앱이 꺼져 있거나 접근이 거부되어도 실행 중인 MCP 서버 버전을 확인할 수 있습니다.

`solnari_status`의 `data.appVersion`과 `data.appBuild`는 실제 실행 중인 앱의 버전과 빌드 번호입니다.
서버 버전과 앱 버전이 다르면 이전 MCP 프로세스 또는 다른 앱 경로가 사용 중인지 확인하세요.
도구 설명 자체에 이전 버전이 보이면 클라이언트가 가져온 도구 목록도 확인해야 합니다.

### 연결별 MCP 동시 실행 수

`연결 설정 → Safety & access → MCP 동시 실행 수`에서 연결별로 1~10개를 지정합니다.
기본값은 3개이며, 기존 저장 연결도 설정이 없으면 3개로 동작합니다. 저장·재연결 시 적용되고
프로필 내보내기·가져오기에도 포함됩니다. `solnari_list_connections`의 `mcpMaxConcurrentQueries`로
설정된 한도를 확인할 수 있습니다.

스키마·객체 조회와 쿼리는 요청마다 별도 DB 세션을 열고 완료·실패 시 닫습니다. 세션을 미리
열어 두지 않으며, 앱의 직접 실행용 세션과 SSH·Kubernetes 터널은 유지합니다. 새 세션의 인증·
연결 비용은 각 요청에 포함됩니다. 같은 DB에서도 설정한 개수까지 동시에 요청할 수 있고,
한도가 찼으면 대기열 없이 `MCP_SESSION_LIMIT_REACHED`로 거절합니다. 서로 다른 연결의 한도는
독립적이며, SQLite 쓰기 잠금 등 DB 자체의 동시 실행 제한은 그대로 적용됩니다.

임시 테이블, 세션 설정, 트랜잭션은 다음 MCP 요청으로 이어지지 않습니다. 트랜잭션을 사용할
때는 해당 엔진이 지원하는 한 번의 SQL 요청 안에서 완료해야 하며, 미완료 트랜잭션은 세션
종료 시 롤백됩니다. 앱 세션에서 아직 커밋하지 않은 변경도 MCP 세션에 공유되지 않습니다.
연결 해제·재연결·DB 전환·시스템 절전·앱 종료 시에는 해당 연결의 MCP 전용 세션도 종료합니다.

접근 권한 변경은 연결 편집에서 저장·재연결해야 하며, 화면의 값만 바뀌어도 이전 읽기 전용
세션의 권한이 상승하지 않습니다.

MCP 접근을 켜고 연결에서 쓰기를 허용하면 INSERT·UPDATE·DELETE·DDL이 DB 계정의 권한 범위에서
즉시 실행됩니다. Solnari에 별도의 건별 승인창은 없으며 외부 MCP 클라이언트의 승인 정책은
그대로 적용됩니다. 시간 초과나 통신 오류 후에는 실행이 이미 완료됐을 수 있으므로 자동으로
재시도하지 말고 DB 상태를 먼저 확인해야 합니다.

응답은 기본 50행, 최대 200행이며 cell당 16 KiB와 전체 응답 2 MB 상한을 적용합니다. 큰
query에는 명시적인 작은 `LIMIT`과 필요한 column만 사용해야 합니다.
`maxRows`와 `returnedRowCount`는 반환 결과 행에 관한 값이며, 변경되는 행의 수를 제한하거나
보고하는 값은 아닙니다. 결과 행이 없어도 변경 SQL은 성공했을 수 있습니다.
PostgreSQL 실행 결과의 `report`에는 드라이버가 보고한 명령과 영향받은 행 수,
트랜잭션 상태가 포함됩니다. 서버 notice와 원본 DB 오류는 앱에만 표시하며 MCP에는
전달하지 않습니다. 접근 거부 응답의 `error` 구조에는 오류 코드, 현재 access level,
요청한 작업, 사용할 도구 및 앱에서 검토·실행하는 다음 단계가 들어갑니다.
`solnari_list_connections` 응답의 연결별 `executionTool`로 선택할 실행 도구를 확인할 수 있습니다.
쓰기 실행 결과가 2 MB를 넘으면 이미 완료된 변경을 실패로 표시하지 않고, 결과 데이터를
생략한 `truncated: true` 성공 응답을 반환합니다.

## 제공하지 않는 정보

MCP 응답에는 다음 항목을 넣지 않습니다.

- database password, OAuth/IAM token과 local vault key
- hostname, port와 username
- Cloud project, region, instance와 IAM principal
- SSH bastion, kube context, namespace와 relay 설정
- 연결되지 않은 저장 profile 또는 해당 session에서 제공하지 않는 database의 schema

연결된 DB의 이름, engine, database 이름, access level, server version·encoding·time zone, schema와
사용자가 요청한 query 결과는 MCP 기능의 목적상 외부 Agent context에 포함될 수 있습니다.

## lifecycle과 한계

- 새 설치에서는 MCP가 꺼져 있습니다.
- Solnari가 실행 중일 때만 socket이 존재합니다.
- socket과 상위 directory는 현재 macOS 사용자만 접근할 수 있습니다.
- 화면 잠금·디스플레이 꺼짐·사용자 session 전환에서는 MCP와 DB 연결을 유지합니다.
- 실제 시스템 절전과 앱 종료 시 socket과 모든 DB 연결을 닫습니다. 시스템 절전 복귀 시 MCP 접근은 재개되지만 DB는 자동 재연결하지 않습니다.
- 이 정책은 Mac의 실제 시스템 절전을 방지하지 않습니다. 화면만 끄더라도 이후 시스템이 절전되면 연결은 종료됩니다. DB·네트워크의 자체 timeout도 그대로 적용됩니다.
- MCP server는 외부 process를 실행하지 않으며 `gcloud`나 proxy fallback을 추가하지 않습니다.
- 같은 macOS 사용자 권한을 탈취한 악성 process까지 격리하는 보안 경계는 아닙니다.
- SQL lexer는 완전한 dialect parser가 아니므로 DB role도 필요한 최소 권한으로 구성해야 합니다.
- remote Streamable HTTP와 OAuth, migration 전용 모드, Solnari의 건별 승인 기능은 제공하지 않습니다.
