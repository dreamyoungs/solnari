# Solnari 공개·릴리스 체크리스트

이 문서는 저장소를 공개하고 macOS 바이너리를 배포할 때 유지관리자가 따르는 기준입니다.
소스 공개와 공식 바이너리 배포는 별개의 단계로 진행합니다.

## 현재 상태

- [x] Apache License 2.0 적용
- [x] README 한국어·영어 지원 범위와 한계 구분
- [x] 기여 안내, 행동 강령, 보안 제보 경로와 변경 기록
- [x] Swift·Node 테스트와 개발용 앱 번들 CI
- [x] npm·Swift·GitHub Actions Dependabot 설정
- [x] 앱 번들에 Solnari·Node.js·Swift/npm 의존성 라이선스 동봉
- [x] 기본 비활성 local MCP와 읽기 전용 도구·사용자 전용 socket 검증
- [x] Developer ID 서명과 notarization용 로컬 패키징 절차
- [ ] GitHub 저장소 `PUBLIC` 전환
- [ ] `main` branch protection과 필수 CI check 설정
- [ ] Developer ID Application 인증서와 notarytool profile 준비
- [ ] notarization된 `v0.1.0` Release 게시

## 1. 공개 전에 확인할 것

1. 저장소 전체에서 실제 project, cluster, namespace, service account, database, hostname,
   IP, credential, SQL, schema와 result를 검색합니다.
2. 예시와 screenshot은 가상 데이터만 사용합니다.
3. README의 **현재 지원**과 **구현 중** 항목이 실제 코드와 일치하는지 확인합니다.
4. `SECURITY.md`의 private advisory URL이 동작하는지 확인합니다.
5. GitHub Actions가 fork pull request에서 secret 없이 `contents: read` 권한만 사용하는지
   확인합니다.
6. 새 설치에서 MCP가 꺼져 있고, 활성화 시 현재 선택한 읽기 전용 연결만 보이는지 확인합니다.

권장 검사:

```bash
rg -n 'PRIVATE KEY|AIza|ya29\.|password|token|authorization' . \
  -g '!backend/node_modules/**' -g '!.build/**'
git status --short
git diff --check
```

검색 결과는 무조건 삭제하지 말고 테스트용 가짜 값과 실제 비밀정보를 구분해서 검토합니다.

## 2. 결정론적 검증

```bash
nvm use # nvm을 사용한다면
npm --prefix backend ci
swift format lint --recursive --strict Sources Tests
swift test
npm --prefix backend run format:check
npm --prefix backend run typecheck
npm --prefix backend test
npm --prefix backend audit --audit-level=low
./Scripts/build-app.sh release
codesign --verify --deep --strict --verbose=2 .build/app/release/Solnari.app
git diff --check
```

Cloud SQL live test는 명시적인 테스트 프로젝트에서만 실행합니다. 운영 정보나 IAM 사용자명을
CI secret, log 또는 공개 fixture로 옮기지 않습니다.

## 3. GitHub 저장소 공개

공개 직전에 다음 저장소 설정을 확인합니다.

- Issues와 private vulnerability reporting 활성화
- Actions workflow 권한을 read-only 기본값으로 제한
- `main`에 pull request와 `CI / Swift, Node, and app bundle` 성공 요구
- force push와 branch 삭제 금지
- secret scanning, push protection과 Dependabot alerts 활성화
- 저장소 설명과 topics 설정

모든 검사가 끝나고 소유자가 최종 확인한 뒤에만 공개로 전환합니다.

```bash
gh repo edit dreamyoungs/solnari \
  --visibility public \
  --accept-visibility-change-consequences
```

이 명령은 되돌릴 때 사용자와 fork에 영향을 줄 수 있으므로 자동화하지 않습니다.

## 4. Developer ID와 notarization 준비

Apple은 Mac App Store 밖에서 배포하는 앱에 Developer ID Application 서명, Hardened
Runtime, secure timestamp와 notarization을 요구합니다. `Scripts/build-app.sh`는 공개 서명
identity가 주어지면 앱과 번들 Node 실행 파일을 각각 서명하고, Node에는 V8 JIT에 필요한
최소 실행 메모리 entitlement를 적용합니다.

1. Apple Developer 계정에서 Developer ID Application 인증서를 준비합니다.
2. Xcode의 `notarytool` credential을 유지관리자 Keychain에 한 번 저장합니다.

```bash
xcrun notarytool store-credentials solnari-notary \
  --apple-id 'APPLE_ID' \
  --team-id 'TEAM_ID'
```

`--password`를 생략하면 `notarytool`이 app-specific password를 안전하게 입력받습니다.
비밀번호나 API key를 저장소, shell history, CI log에 남기지 않습니다.

## 5. 공식 앱 패키징

```bash
export SOLNARI_CODESIGN_IDENTITY='Developer ID Application: NAME (TEAM_ID)'
export SOLNARI_NOTARY_KEYCHAIN_PROFILE='solnari-notary'
./Scripts/package-release.sh
```

스크립트는 다음을 fail-closed로 수행합니다.

1. Node backend와 Release app build
2. 번들 Node와 앱의 Developer ID·Hardened Runtime 서명
3. Solnari와 모든 bundled dependency license 동봉
4. ZIP을 `notarytool`에 제출하고 완료 대기
5. notarization ticket stapling과 Gatekeeper 평가
6. architecture가 표시된 최종 ZIP과 SHA-256 파일 생성

Apple Silicon에서 만든 앱은 `arm64`, Intel에서 만든 앱은 `x86_64`입니다. universal binary를
제공한다고 표시하려면 두 architecture를 실제로 결합하고 각각의 Node runtime까지 다시
검증해야 합니다.

## 6. 태그와 GitHub Release

1. `CHANGELOG.md`, `CFBundleShortVersionString`과 `CFBundleVersion`을 갱신합니다.
2. release commit을 만들고 CI 성공을 확인합니다.
3. annotated tag를 만들고 push합니다.
4. notarization된 ZIP과 SHA-256 파일만 Release asset으로 첨부합니다.

```bash
git tag -a v0.1.0 -m 'Solnari 0.1.0'
git push origin v0.1.0
gh release create v0.1.0 \
  .build/release/Solnari-0.1.0-macos-arm64.zip \
  .build/release/Solnari-0.1.0-macos-arm64.zip.sha256 \
  --title 'Solnari 0.1.0' \
  --notes-file CHANGELOG.md
```

실제 artifact 이름은 package script 출력과 일치시킵니다. 개발용 ad-hoc app이나 notarization
전 archive를 공식 Release에 올리지 않습니다.

## 7. 게시 후 확인

- 깨끗한 Mac 사용자 계정에서 ZIP 다운로드, 압축 해제와 최초 실행
- Gatekeeper 경고에 확인된 개발자 이름 표시
- `spctl` assessment와 stapler validation 성공
- 한국어·영어 최초 화면과 연결 생성
- 앱 종료 뒤 Node, SSH, kubectl 또는 listening port가 남지 않음
- README 다운로드 링크와 checksum 일치

공개 뒤 발견한 credential 노출은 commit 삭제만으로 끝내지 않고 즉시 credential을 폐기·회전한
후 GitHub 지원 절차를 포함한 history 정리를 진행합니다.

## 참고

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [GitHub: Dependabot supported ecosystems](https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories)
