# OpenGrok Index Scheduler

70개 이상의 OpenGrok 서비스 컨테이너를 효율적으로 인덱싱하기 위한 Bash 기반 인덱스 스케줄러입니다. 서버의 부하 상태를 실시간으로 모니터링하여 가용 리소스가 충분할 때만 작업을 수행하며, 지정된 야간 시간대에 순차적으로 작업을 관리합니다.

## 주요 기능

- **시간 기반 스케줄링**: 설정된 시간대 (예: 18:00 ~ 익일 06:00) 내에서만 인덱싱 작업 수행
- **리소스 모니터링**: CPU, Memory, Disk, Process 사용율을 5분 주기로 검사하여 모두 70% 이하일 때만 신규 작업 착수
- **SQLite3 기반 관리**: 서비스 목록, 스케줄러 설정, 작업 로그 및 상태를 SQLite3 DB로 통합 관리
- **상태 리포팅**: `--status` 명령어를 통해 처리 현황, 시작 시간, 소요 시간, 결과 등을 콘솔에 출력
- **독립적 구동**: 스케줄러가 백그라운드에서 실행 중이더라도 별도 세션에서 상태 확인 가능

## 프로젝트 구조

```text
opengrok-scheduler/
├── bin/
│   ├── scheduler.sh    # 메인 스케줄러 및 CLI 인터페이스
│   ├── monitor.sh      # 시스템 리소스 모니터링 모듈
│   └── db_query.sh     # SQLite3 쿼리 유틸리티
├── sql/
│   └── init_db.sql     # 데이터베이스 스키마 및 초기 설정
├── data/
│   └── scheduler.db    # 생성된 SQLite3 데이터베이스 파일
├── tests/              # TDD를 위한 단계별 테스트 스크립트
├── logs/               # 실행 로그 보관 디렉토리
├── README.md           # 프로젝트 가이드
├── SPEC.md             # 상세 개발 규격서
└── TASK.md             # 구현 진행 기록
```

## 설치 및 시작하기

### 1. 사전 요구사항
- Bash Shell
- SQLite3
- Docker (인덱싱 대상 서비스가 컨테이너로 구동 중이어야 함)

### 2. 데이터베이스 초기화
```bash
mkdir -p data logs
sqlite3 data/scheduler.db < sql/init_db.sql
```

### 3. 서비스 등록
인덱싱이 필요한 도커 컨테이너들을 등록합니다.
```bash
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('opengrok-service-1', 10);"
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('opengrok-service-2', 5);"
```

### 4. 스케줄러 실행
```bash
chmod +x bin/*.sh
./bin/scheduler.sh
```

## 사용 방법

### 특정 서비스 단독 실행 (--service)
스케줄 시간이나 리소스 상태와 관계없이 특정 컨테이너를 즉시 인덱싱합니다.
```bash
./bin/scheduler.sh --service opengrok-service-1
```

### 상태 확인 (--status)
현재 스케줄러의 진행 상황과 작업 이력을 요약하여 출력합니다.
```bash
./bin/scheduler.sh --status
```

**출력 예시:**
```text
[OpenGrok Indexing Summary]
--------------------------------------------------------------------------------
Service Name              | Status       | Start Time           | Duration     | Result    
--------------------------------------------------------------------------------
opengrok-service-1        | COMPLETED    | 2026-02-26 18:00:01  | 0h 45m 20s   | COMPLETED 
opengrok-service-2        | RUNNING      | 2026-02-26 18:45:30  | -            | IN_PROGRESS
...
--------------------------------------------------------------------------------
Total: 70 | Done Today: 15
```

### 설정 변경 (SQLite3 활용)
작업 시간대나 리소스 임계치를 DB에서 즉시 변경할 수 있습니다.
```bash
# 시작 시간을 20:00로 변경
./bin/db_query.sh "UPDATE config SET value='20:00' WHERE key='start_time';"
```

## 테스트 실행
각 모듈의 정상 동작을 확인하려면 `tests/` 디렉토리의 스크립트를 실행합니다.
```bash
./tests/test_monitor.sh           # 리소스 모니터링 엔진 테스트
./tests/test_scheduler_logic.sh   # 시간대 및 대기 로직 테스트
./tests/test_status_output.sh     # CLI 출력 포맷 테스트
```
