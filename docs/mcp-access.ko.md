# 외부 Agent용 MCP 접근

Solnari는 로컬 Codex desktop app, CLI 또는 IDE extension이 현재 앱에서 선택한 database를
제한적으로 탐색할 수 있는 STDIO MCP server를 제공합니다. 앱 내부 Codex chat prototype과는
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
  → currently selected database session
```

MCP process는 database profile이나 credential vault를 직접 읽지 않습니다. Solnari app이 연결,
credential, transport와 database session을 계속 소유하고 MCP process는 사용자 전용 local
socket으로 정형화된 요청만 전달합니다.

## 활성화와 등록

1. Solnari의 `설정 → MCP 접근`을 엽니다.
2. `로컬 MCP 접근 허용`을 켭니다.
3. 표시되는 `Codex 등록 명령 복사`를 누릅니다.
4. 복사한 `codex mcp add solnari -- ...` 명령을 Terminal에서 한 번 실행합니다.
5. Codex desktop app, CLI 또는 IDE extension을 재시작합니다.
6. Codex에서 `/mcp` 또는 MCP server 설정을 열어 `solnari` 연결을 확인합니다.

등록 명령은 설치된 app 내부의 bundled Node runtime과 MCP entrypoint를 절대 경로로 지정합니다.
비밀번호, token 또는 database 정보는 명령 인자나 환경 변수에 포함하지 않습니다.

## 제공 도구

| 도구 | 동작 |
| --- | --- |
| `solnari_status` | 실행 중인 Solnari MCP bridge 상태 확인 |
| `solnari_get_active_connection` | 현재 선택한 연결의 정제된 metadata 확인 |
| `solnari_list_schema` | 현재 연결의 table, view, materialized view와 function 목록 |
| `solnari_describe_object` | column, index, constraint, comment와 definition 조회 |
| `solnari_execute_read_query` | 읽기 전용 profile에서 단일 read query 실행 |

모든 도구는 MCP `readOnlyHint`를 사용합니다. 쿼리 도구는 Codex의 approval 설정과 별개로
Solnari에서도 다음 조건을 모두 검사합니다.

- MCP 접근이 켜져 있음
- Mac이 잠금·절전 상태가 아님
- 앱에서 선택한 profile이 이미 연결됨
- profile access level이 `Read-only`
- SQL 사전 검사가 단일 read statement로 판정함
- database session 자체도 write를 거부하도록 설정됨

응답은 기본 50행, 최대 200행이며 cell당 16 KiB와 전체 응답 2 MB 상한을 적용합니다. 큰
query에는 명시적인 작은 `LIMIT`과 필요한 column만 사용해야 합니다.

## 제공하지 않는 정보

MCP 응답에는 다음 항목을 넣지 않습니다.

- database password, OAuth/IAM token과 local vault key
- hostname, port와 username
- Cloud project, region, instance와 IAM principal
- SSH bastion, kube context, namespace와 relay 설정
- 다른 저장 연결 또는 현재 선택하지 않은 database의 schema

현재 연결 이름, engine, database 이름, access level, server version·encoding·time zone, schema와
사용자가 요청한 read query 결과는 MCP 기능의 목적상 외부 Agent context에 포함될 수 있습니다.

## lifecycle과 한계

- 새 설치에서는 MCP가 꺼져 있습니다.
- Solnari가 실행 중일 때만 socket이 존재합니다.
- socket과 상위 directory는 현재 macOS 사용자만 접근할 수 있습니다.
- 화면 잠금, 절전, 사용자 session 전환과 앱 종료 시 socket을 닫습니다.
- MCP server는 외부 process를 실행하지 않으며 `gcloud`나 proxy fallback을 추가하지 않습니다.
- 같은 macOS 사용자 권한을 탈취한 악성 process까지 격리하는 보안 경계는 아닙니다.
- SQL lexer는 완전한 dialect parser가 아니므로 실제 database role도 최소 읽기 권한이어야 합니다.
- remote Streamable HTTP와 OAuth, write tool, migration, 자동 승인 기능은 제공하지 않습니다.
