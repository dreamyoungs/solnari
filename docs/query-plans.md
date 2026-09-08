# 쿼리 실행 계획

연결된 데이터베이스에서 **실행 계획**을 누르면 편집기의 단일 SQL을 별도로 감싸 결과 영역에 표시합니다. 원본 SQL과 일반 조회 결과는 보존됩니다. **계획 SQL 복사**로 실제 전송한 문장을 확인할 수 있습니다.

- PostgreSQL / MySQL: `EXPLAIN`
- SQLite: `EXPLAIN QUERY PLAN`

기본 SELECT, WITH, INSERT, UPDATE, DELETE를 지원하며, 나머지 문장과 기존 EXPLAIN 접두사, 여러 문장, 미완성 인용/주석, 실행형 주석은 거부합니다. 서버의 escape 설정에 따라 해석이 달라질 수 있는 인용부의 역슬래시는 보수적으로 거부합니다. DB 권한과 기존 읽기 전용 정책도 계속 적용됩니다.

`EXPLAIN ANALYZE`는 문장을 실제로 실행하므로 초기 범위에서 제외합니다. 일반 실행 계획도 서버의 계획 수립과 잠금, 권한 검사를 수반하며 비용이 없는 작업은 아닙니다. 조회는 현재 세션을 사용하므로 세션의 임시 객체를 볼 수 있습니다. 30초 제한 또는 취소 시 연결을 닫아 작업을 정리하고 재접속을 요구합니다. 이때 현재 세션의 트랜잭션·임시 상태도 종료됩니다.

SQL, 실행 계획, 연결 정보는 외부 분석 서비스로 전송하지 않습니다.

공식 명령 문서: [PostgreSQL](https://www.postgresql.org/docs/current/sql-explain.html), [MySQL](https://dev.mysql.com/doc/refman/8.4/en/explain.html), [SQLite](https://sqlite.org/eqp.html).
