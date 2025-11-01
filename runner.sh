#!/bin/bash

# 로그 파일 이름 설정
LOG_FILE="localCombined.log"
PIDS_DIR="./processPids" # PID 파일을 저장할 디렉토리
LOCK_FILE="processControl.lock"

# 초기 설정
mkdir -p "$PIDS_DIR"


# ----------------------------------------------------
# start (모든 프로세스를 초기 시작)
# ----------------------------------------------------
start_all() {
    
    rm -f "$LOG_FILE"
    touch "$LOG_FILE"

    {

        # 1. 하위 디렉토리를 순회하며 명령어 생성
        # 현재 디렉토리(.)를 기준으로 하위 디렉토리(* /)를 찾습니다.
        for dir in */; do
            # 디렉토리 이름에서 마지막 슬래시(/)를 제거하여 프로세스 이름으로 사용합니다.
            process_name=${dir%/}

            # 원하지 않은 디렉토리 건너뛰기
            if [[ "$process_name" == "processPids" ]]; then
                continue
            fi
            
            # stdbuf와 go run 명령어를 구성합니다.
            cmd="stdbuf -oL -eL go run ./${process_name}/cmd ${process_name}"
            
            # 💡 수정 1: 모든 출력을 임시 FIFO(Named Pipe)로 보냅니다.
            # FIFO를 사용하는 복잡성을 피하고, 단순하게 각 출력을 메인 서브셸의 표준 출력으로 보냅니다.
            
            # 💡 핵심 로직: 각 프로세스를 백그라운드로 실행하고, 그 출력을 sed로 처리하여 표준 출력으로 보냅니다.
            # sed가 메인 서브셸의 직접적인 자식 프로세스가 되도록 구조를 단순화합니다.
            
            # go run 프로세스 실행 (2>&1로 에러를 표준 출력으로 병합)
            # sed를 이용해 프로세스 이름 태그를 붙입니다.
            $cmd 2>&1 | sed -u "s/^/[${process_name}] /" & 
            
            # sed 파이프라인의 마지막 명령어인 sed의 PID를 메인 셸의 PIDS_FILE에 기록합니다.
            # 이제 이 PID들은 이 서브셸의 직접적인 자식(Child)입니다.
            echo $! >> "${PIDS_DIR}/${process_name}.pid"
        done
        
        # 💡 수정 2: PIDS_FILE에 기록된 PID들(sed 프로세스들)의 종료를 안전하게 기다립니다
        if [ -s "${PIDS_DIR}/${process_name}.pid" ]; then
            echo "(go run | sed)백그라운드 프로세스 종료 대기 중 (== go run cmd 시작되기까지 대기 중)..."
            wait $(cat "${PIDS_DIR}/${process_name}.pid")
        fi

    # { ... } 블록의 모든 출력을 하나의 파이프로 묶습니다.
    # 모든 출력이 셸 그룹의 표준 출력으로 병합된 후, 최종적으로 awk로 전달됩니다.
    } 2>&1 | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush() }' >> "$LOG_FILE"
}

# ----------------------------------------------------
# restart : 특정 프로세스 이름(서비스 이름)을 받아 처리
# ----------------------------------------------------
restart_process() {
    local process_name=$1
    local pid_file="${PIDS_DIR}/${process_name}.pid"

    echo "--- 서비스 재시작 요청: ${process_name} ---"

    # 1.1. 기존 프로세스 종료 (Shutdown)
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "기존 PID ${old_pid} 종료 중..." | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), "[CONTROL]", $0 }' >> "$LOG_FILE"
            kill "$old_pid"
            # 프로세스가 완전히 종료될 때까지 대기
            wait "$old_pid" 2>/dev/null
        else
            echo "PID ${old_pid}는 이미 종료되었거나 유효하지 않습니다."
        fi
        rm -f "$pid_file"
    else
        echo "경고: ${process_name}에 대한 실행 중인 PID 파일이 없습니다. 새롭게 시작합니다." | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), "[CONTROL]", $0 }' >> "$LOG_FILE"
    fi

    # 1.2. 새로운 프로세스 시작 (Startup)
    local cmd="stdbuf -oL -eL go run ./${process_name}/cmd ${process_name}"
    
    # 새로운 파이프라인 시작. 출력을 직접 로그 파일로 리다이렉션.
    # 이전의 복잡한 wait 구조 대신, 각 프로세스의 출력을 최종 로그 파일로 직접 보냅니다.
    # 이렇게 하면 개별 프로세스가 재시작되어도 기존 로그 파일에 계속 추가됩니다.
    (
        $cmd 2>&1 | sed -u "s/^/[${process_name}] /"
    ) 2>&1 | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush() }' >> "$LOG_FILE" &
    
    # 새로 시작된 프로세스의 PID (여기서는 awk의 PID)를 저장합니다.
    echo $! > "$pid_file"
    echo "${process_name} 서비스가 새로운 PID $(cat "$pid_file")로 재시작되었습니다." | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), "[CONTROL]", $0 }' >> "$LOG_FILE"
}

stop_all(){
    for dir in */; do
        # 디렉토리 이름에서 마지막 슬래시(/)를 제거하여 프로세스 이름으로 사용합니다.
        process_name=${dir%/}
        local pid_file="${PIDS_DIR}/${process_name}.pid"

        # 원하지 않은 디렉토리 건너뛰기
        if [[ "$process_name" == "processPids" ]]; then
            continue
        fi

            # 1.1. 기존 프로세스 종료 (Shutdown)
        if [ -f "$pid_file" ]; then
            local old_pid=$(cat "$pid_file")
            if kill -0 "$old_pid" 2>/dev/null; then
                echo "기존 PID ${old_pid} 종료 중..." | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), "[CONTROL]", $0 }' >> "$LOG_FILE"
                kill "$old_pid"
                # 프로세스가 완전히 종료될 때까지 대기
                wait "$old_pid" 2>/dev/null
            else
                echo "PID ${old_pid}는 이미 종료되었거나 유효하지 않습니다."
            fi
            rm -f "$pid_file"
        fi

    done
}

# ----------------------------------------------------
# stop : 특정 프로세스 이름(서비스 이름)을 받아 처리
# ----------------------------------------------------
stop_process() {
    local process_name=$1
    local pid_file="${PIDS_DIR}/${process_name}.pid"

    echo "--- 서비스 정지 요청: ${process_name} ---"

    # 1.1. 기존 프로세스 종료 (Shutdown)
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "기존 ${process_name}(${old_pid}) 종료 중..." | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), "[CONTROL]", $0 }' >> "$LOG_FILE"
            kill "$old_pid"
            # 프로세스가 완전히 종료될 때까지 대기
            wait "$old_pid" 2>/dev/null
        else
            echo "PID ${old_pid}는 이미 종료되었거나 유효하지 않습니다."
        fi
        rm -f "$pid_file"
    else
        echo "경고: ${process_name}에 대한 실행 중인 PID 파일이 없습니다. 새롭게 시작합니다." | awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), "[CONTROL]", $0 }' >> "$LOG_FILE"
    fi

    echo "${process_name} 서비스가 정지되었습니다"
}

# ----------------------------------------------------
# 스크립트 실행 모드
# ----------------------------------------------------
case "$1" in
    start)
        # 스크립트가 이미 실행 중인지 확인 (다중 실행 방지)
        if [ -f "$LOCK_FILE" ]; then
            echo "이미 프로세스 컨트롤러가 실행 중입니다. 기존의 모든 프로세스 종료 후 전체 서비스를 재시작합니다."
            rm -f "$LOCK_FILE"
            stop_all
        fi
        touch "$LOCK_FILE"
        start_all
        exit 1
        ;;
    restart)
        if [ -z "$2" ]; then
            echo "사용법: $0 restart <프로세스 이름>"
            exit 1
        fi
        restart_process "$2"
        ;;
    stop)
        echo "프로세스 컨트롤러를 종료합니다."
        if [ -z "$2" ]; then
            echo "모든 프로세스를 정지합니다."
            rm -f "$LOG_FILE"
            rm -f "$LOCK_FILE"
            exit 1
        fi
        stop_process "$2"
        ;;
    *)
        echo "사용법: $0 [start | restart | stop <프로세스 이름>]"
        exit 1
        ;;
esac
