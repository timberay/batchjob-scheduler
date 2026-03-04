# OpenGrok Index Scheduler Architecture

OpenGrok 인덱싱 작업을 효율적으로 관리하기 위한 Bash 기반 스케줄러의 아키텍처 및 상세 설계서입니다.

## 1. 개요
70개 이상의 OpenGrok 서비스 컨테이너를 특정 시간대(18:00 ~ 06:00, 설정 가능)에 순차적으로 인덱싱하며, 서버 부하(CPU, Memory, Disk, Process)를 실시간 모니터링하여 안정적인 인덱싱 환경을 제공합니다.

## 2. 주요 기능
- **시간대 관리**: 지정된 작업 시간대 내에서만 인덱싱 스크립트 실행.
- **정밀한 리소스 모니터링**: 
  - **CPU**: `top` 2회 측정을 통해 부팅 평균이 아닌 **현재 시점의 실제 부하** 반영.
  - **Memory**: 캐시/버퍼를 제외한 **실질 가용 메모리(`available`)** 기준 판단.
  - **Network**: 인터페이스 속도 자동 감지 및 실시간 대역폭 사용량(% ) 계산.
  - **Process**: 실행 중(Running), 대기(Blocked) 프로세스 상태를 종합한 Busy Score 산출.
- **순차 처리**: 70개 이상의 서비스 목록을 데이터베이스 우선순위에 기반하여 순차적으로 실행.
- **실시간 로깅**: 모든 작업 상태 및 지표를 SQLite3 DB 및 로그 파일에 저장.
- **상태 리포팅**: `--status` 명령어를 통해 처리 현황 및 통계 정보 요약 출력.

## 3. 기술 스택
- **Language**: Bash Script
- **Database**: SQLite3
- **Container**: Docker CLI
- **Monitoring**: `top`, `free`, `iostat` (sysstat), `/proc/net/dev`, `/sys/class/net/`

## 4. 데이터베이스 설계 (sqlite3)

### 4.1 `config` 테이블
스케줄러 동작 설정을 관리합니다.
- `id`: INTEGER PRIMARY KEY
- `key`: TEXT UNIQUE (e.g., 'start_time', 'resource_threshold', 'net_interface', 'max_bandwidth', 'disk_device')
- `value`: TEXT

### 4.2 `services` 테이블
인덱싱할 대상 목록을 관리합니다.
- `id`: INTEGER PRIMARY KEY
- `container_name`: TEXT UNIQUE (도커 컨테이너 이름)
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
   - 아닐 경우: 임계 시간(`check_interval`) 대기 후 회귀.
3. 시스템 리소스를 체크합니다 (`bin/monitor.sh`).
   - CPU, MEM, DISK, DISKIO, NET, PROC 점수 중 하나라도 임계치 이상인 경우: 대기.
4. `services` 테이블에서 다음 실행 대상(최근 20시간 내 미수행 또는 실패 항목)을 우선순위 순으로 조회합니다.
5. 인덱싱 작업을 수행하고 결과를 DB에 업데이트합니다.

### 5.2 리소스 체크 상세 기준
- **CPU**: `top -bn2` 결과의 `%idle`을 뺀 값 (순간 부하).
- **Memory**: `(Total - Available) / Total * 100` (실질 메모리 압박).
- **Disk I/O**: `iostat -dx`의 `%util` 지표.
- **Network**: 초당 전송량 / 인터페이스 최대 대역폭 (자동 감지 또는 설정값).
- **Process Score**: `procs_running`, `procs_blocked` 및 실행 상태 비율 중 최대값.

## 6. CLI 인터페이스

### 6.1 `--status` 명령 실행
메인 스케줄러의 실행 여부와 관계없이 독립적으로 구동 가능합니다.

**출력 형식:**
- 각 서비스별 상태 (Status), 시작 시간 (Start Time), 소요 시간 (Duration), 결과 (Result).
- 최근 20시간 기준의 전체 진행 현황 (Done / Total).

## 7. 예외 처리
- **로캘 대응**: `free -m` 등 시스템 도구 결과 파싱 시 언어 설정(Korean/English)에 영향받지 않도록 인덱스 기반 파싱.
- **네트워크 속도 감지**: `/sys/class/net/` 접근 실패 시 기본값(100Mbps)으로 안전하게 폴백.
- **DB 잠금**: 작업 시작 시각과 종료 시각을 명확히 기록하여 중복 실행 방지.
