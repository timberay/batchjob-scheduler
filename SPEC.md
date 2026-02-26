# OpenGrok Index Scheduler Specification (SPEC)

OpenGrok 인덱싱 작업을 효율적으로 관리하기 위한 Bash 기반 스케줄러의 개발 규격서입니다.

## 1. 개요
70개 이상의 OpenGrok 서비스 컨테이너를 야간 시간대(18:00 ~ 06:00, 설정 가능)에 순차적으로 인덱싱하며, 서버 부하(CPU, Memory, Disk, Process)를 실시간 모니터링하여 안정적인 인덱싱 환경을 제공합니다.

## 2. 주요 기능
- **시간대 관리**: 지정된 작업 시간대 내에서만 인덱싱 스크립트 실행.
- **리소스 모니터링**: 5분 주기로 CPU, Memory, Disk, Process 사용율을 검사하여 모두 70% 이하일 때만 신규 작업 착수.
- **순차 처리**: 70개 이상의 서비스 목록을 데이터베이스에 기반하여 순보적으로 실행.
- **실시간 로깅**: 모든 작업 상태 및 지표를 SQLite3 DB에 저장.
- **상태 리포팅**: `--status` 명령어를 통해 처리 현황 및 통계 정보 요약 출력.

## 3. 기술 스택
- **Language**: Bash Script
- **Database**: SQLite3
- **Container**: Docker (Docker API 또는 CLI 활용)
- **Monitoring**: OS 기본 도구 (`top`, `ps`, `df`, `free` 등)

## 4. 데이터베이스 설계 (sqlite3)

### 4.1 `config` 테이블
스케줄러 동작 설정을 관리합니다.
- `id`: INTEGER PRIMARY KEY
- `key`: TEXT (e.g., 'start_time', 'end_time', 'resource_threshold', 'check_interval')
- `value`: TEXT (e.g., '18:00', '06:00', '70', '300')

### 4.2 `services` 테이블
인덱싱할 대상 목록을 관리합니다.
- `id`: INTEGER PRIMARY KEY
- `container_name`: TEXT (도커 컨테이너 이름)
- `priority`: INTEGER (실행 우선순위, 기본값 0)
- `is_active`: INTEGER (1: 실행대상, 0: 제외)

### 4.3 `jobs` 테이블
작업 결과 및 로그를 관리합니다.
- `id`: INTEGER PRIMARY KEY
- `service_id`: INTEGER (services.id 외래키)
- `status`: TEXT ('WAITING', 'RUNNING', 'COMPLETED', 'FAILED')
- `start_time`: DATETIME
- `end_time`: DATETIME
- `duration`: INTEGER (소요 시간, 초 단위)
- `message`: TEXT (에러 메시지 등)

## 5. 핵심 알고리즘 및 동작 프로세스

### 5.1 메인 루프 (Main Loop)
1. DB에서 `config` 정보를 로드합니다.
2. 현재 시간이 `start_time` ~ `end_time` 사이인지 확인합니다.
   - 아닐 경우: 5분(설정값) 대기 후 1번으로 회귀.
3. 시스템 리소스를 체크합니다.
   - CPU, MEM, DISK, PROC 사용량 중 하나라도 70%(설정값) 이상인 경우: Log 남기고 대기(Sleep 300).
4. `services` 테이블에서 다음 실행 대상(상태가 WAITING이거나 미수행인 항목)을 확인합니다.
5. 인덱싱 스크립트(Docker exec 등)를 구동하고 `jobs` 테이블 상태를 `RUNNING`으로 변경합니다.
6. 작업 완료 후 `end_time`, `duration`, `status`를 업데이트합니다.

### 5.2 리소스 체크 기준 (Threshold: 70%)
- **CPU**: `100 - idle` 값 기준.
- **Memory**: `Used / Total` 비중 기준.
- **Disk**: 오픈그록 데이터 저장 파티션의 사용량 (`df` 기준).
- **Process**: 전체 프로세스 개수 또는 특정 부하 지표.

## 6. CLI 인터페이스

### 6.1 `--status` 명령 실행
메인 스케줄러의 실행 여부와 관계없이 독립적으로 구동 가능해야 합니다.

**출력 형식 예시:**
```text
[OpenGrok Indexing Summary]
--------------------------------------------------------------------------------
Service Name       | Status     | Start Time          | Duration | Result
--------------------------------------------------------------------------------
service-a-container| COMPLETED  | 2026-02-26 18:00:01 | 45m 20s  | SUCCESS
service-b-container| RUNNING    | 2026-02-26 18:45:21 | -        | IN_PROGRESS
service-c-container| WAITING    | -                   | -        | PENDING
...
--------------------------------------------------------------------------------
Total: 70 | Done: 15 | Remaining: 55 | Failed: 0
```

## 7. 예외 처리
- **작업 시간 종료**: 06:00 도래 시, 현재 실행 중인 도커 작업은 완료될 때까지 대기하거나 종료 옵션에 따르고, 다음 신규 작업은 시작하지 않음.
- **DB 잠금 방지**: SQLite3 접근 시 `timeout` 옵션을 활용하여 동시 접근 에러 방지.
- **리소스 부족**: 작업 중 리소스가 부족해져도 이미 시작된 인덱싱은 중단하지 않으며, 다음 작업 시작 직전에만 확인.
