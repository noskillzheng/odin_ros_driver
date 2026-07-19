#!/bin/bash

# tmux-launch.sh - 作为 RMCS 服务的一部分启动 Odin1。
#
# 行为：若已有旧的 Odin1 进程（host_sdk_sample）或残留 tmux 会话，
# 先完全清理（C-c → SIGTERM → SIGKILL 兜底），再在 tmux 会话 "odin"
# 中重新启动。查看运行情况：tmux attach -t odin

set -u

readonly SESSION="odin"
readonly EXECUTABLE="host_sdk_sample"
readonly GRACE=5          # 优雅退出等待秒数
readonly POLL_INTERVAL=0.2

env_setup_file="${HOME}/env_setup.bash"

has_session() {
    tmux has-session -t "${SESSION}" 2>/dev/null
}

proc_running() {
    pgrep -x "${EXECUTABLE}" >/dev/null 2>&1
}

# 完全清理旧的 Odin1：C-c → 轮询等待 → TERM → KILL 兜底，最后回收 tmux 会话。
cleanup() {
    if ! has_session && ! proc_running; then
        return 0
    fi

    echo "Stopping old Odin1 process..."

    # 1. 发 Ctrl+C，触发 host_sdk_sample 自带的干净关闭（释放 USB）
    if has_session; then
        tmux send-keys -t "${SESSION}" C-c 2>/dev/null || true
    fi

    # 2. 轮询等待进程真正消失（最多 GRACE 秒）
    local max_iter
    max_iter=$(awk "BEGIN{print int(${GRACE} / ${POLL_INTERVAL})}")
    local i=0
    while [ "${i}" -lt "${max_iter}" ]; do
        if ! proc_running; then
            break
        fi
        sleep "${POLL_INTERVAL}"
        i=$((i + 1))
    done

    # 3. 超时仍在 → 升级 SIGTERM
    if proc_running; then
        echo "Odin1 did not exit within ${GRACE}s, sending SIGTERM..."
        pkill -TERM -x "${EXECUTABLE}" 2>/dev/null || true
        sleep 1
    fi

    # 4. 仍在 → SIGKILL 兜底强杀（必然释放 USB）
    if proc_running; then
        echo "Odin1 still alive, sending SIGKILL..."
        pkill -KILL -x "${EXECUTABLE}" 2>/dev/null || true
        sleep 0.5
    fi

    # 5. 回收 tmux 会话（此时进程已确认退出）
    if has_session; then
        tmux kill-session -t "${SESSION}" 2>/dev/null || true
    fi

    if proc_running; then
        echo "Error: failed to stop old Odin1 (${EXECUTABLE} still present)."
        return 1
    fi

    echo "Old Odin1 process cleaned up."
    return 0
}

launch() {
    cleanup || return 1

    # 给 USB 句柄一点释放时间，避免 LIBUSB_ERROR_BUSY
    sleep 1

    if [ ! -f "${env_setup_file}" ]; then
        echo "Error: '${env_setup_file}' not found. Cannot source ROS environment."
        return 1
    fi

    echo "Starting Odin1..."
    # tmux 用 default-shell（可能是 zsh）执行命令字符串，而 env_setup.bash
    # 及其内部的 ROS setup 脚本依赖 BASH_SOURCE，必须由 bash source；
    # exec 链让 host_sdk_sample 最终成为 window 的直接前台进程，
    # 这样 cleanup() 的 send-keys C-c 才能精确送达它本身。
    tmux new-session -d -s "${SESSION}" \
        "exec bash -c \"source '${env_setup_file}' && exec ros2 run odin_ros_driver ${EXECUTABLE}\""

    # ros2 run 先起 python 包装进程，${EXECUTABLE} 稍后才出现，轮询等待
    local max_iter
    max_iter=$(awk "BEGIN{print int(${GRACE} / ${POLL_INTERVAL})}")
    local i=0
    while [ "${i}" -lt "${max_iter}" ]; do
        if proc_running; then
            break
        fi
        if ! has_session; then
            break  # 会话已退出，进程不可能再出现
        fi
        sleep "${POLL_INTERVAL}"
        i=$((i + 1))
    done

    if has_session && proc_running; then
        echo "Successfully started Odin1. (view with: tmux attach -t ${SESSION})"
        return 0
    else
        echo "Error: failed to start Odin1."
        # 清理可能残留的空壳会话
        tmux kill-session -t "${SESSION}" 2>/dev/null || true
        return 1
    fi
}

launch
