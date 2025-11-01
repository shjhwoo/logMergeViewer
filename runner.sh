#!/bin/bash

# 로그 파일 이름 설정
LOG_FILE="local_combined.log"

rm -f "$LOG_FILE"

# 임시 파일 설정: go run 프로세스들을 백그라운드로 실행하면서 그들의 PID를 저장합니다.
PIDS_FILE=$(mktemp)

{
    # 1. 하위 디렉토리를 순회하며 명령어 생성
    # 현재 디렉토리(.)를 기준으로 하위 디렉토리(* /)를 찾습니다.
    for dir in */; do
        # 디렉토리 이름에서 마지막 슬래시(/)를 제거하여 프로세스 이름으로 사용합니다.
        process_name=${dir%/}
        
        # stdbuf와 go run 명령어를 구성합니다.
        cmd="stdbuf -oL -eL go run ./${process_name}/cmd ${process_name}"
        
        # 💡 수정 1: 모든 출력을 임시 FIFO(Named Pipe)로 보냅니다.
        # FIFO를 사용하는 복잡성을 피하고, 단순하게 각 출력을 메인 서브셸의 표준 출력으로 보냅니다.
        
        # 💡 핵심 로직: 각 프로세스를 백그라운드로 실행하고, 그 출력을 sed로 처리하여 표준 출력으로 보냅니다.
        # sed가 메인 서브셸의 직접적인 자식 프로세스가 되도록 구조를 단순화합니다.
        
        # go run 프로세스 실행 (2>&1로 에러를 표준 출력으로 병합)
        # sed를 이용해 프로세스 이름 태그를 붙입니다.
        $cmd 2>&1 | sed "s/^/[${process_name}] /" & 
        
        # sed 파이프라인의 마지막 명령어인 sed의 PID를 메인 셸의 PIDS_FILE에 기록합니다.
        # 이제 이 PID들은 이 서브셸의 직접적인 자식(Child)입니다.
        echo $! >> "$PIDS_FILE"

    done

    # 잠시 대기: 모든 백그라운드 프로세스가 제대로 시작되도록 합니다.
    sleep 1
    
    # 💡 수정 2: PIDS_FILE에 기록된 PID들(sed 프로세스들)의 종료를 안전하게 기다립니다
    if [ -s "$PIDS_FILE" ]; then
        echo "(go run | sed)백그라운드 프로세스 종료 대기 중(== go run cmd 시작되기까지 대기 중)..."
        wait $(cat "$PIDS_FILE")
    fi

# { ... } 블록의 모든 출력을 하나의 파이프로 묶습니다.
# 모든 출력이 셸 그룹의 표준 출력으로 병합된 후, 최종적으로 awk로 전달됩니다.
} 2>&1 | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }' >> "$LOG_FILE"


# 3. 정리
# 임시 파일 삭제
rm "$PIDS_FILE"

echo "모든 백그라운드 프로세스가 완료되었으며, 로그는 $LOG_FILE에 저장되었습니다."