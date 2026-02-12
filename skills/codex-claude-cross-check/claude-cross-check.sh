#!/usr/bin/env bash

set -euo pipefail
set +m

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <prompt>" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
user_prompt="$*"

timeout_seconds="${CLAUDE_TIMEOUT_SECONDS:-90}"
max_attempts="${CLAUDE_MAX_ATTEMPTS:-2}"
scan_max_bytes="${CLAUDE_SCAN_MAX_BYTES:-524288}"

if ! [[ "${timeout_seconds}" =~ ^[0-9]+$ ]] || (( timeout_seconds < 1 )); then
    timeout_seconds=90
fi

if ! [[ "${max_attempts}" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
    max_attempts=2
fi

if ! [[ "${scan_max_bytes}" =~ ^[0-9]+$ ]] || (( scan_max_bytes < 1024 )); then
    scan_max_bytes=524288
fi

if ! command -v claude >/dev/null 2>&1; then
    echo "claude command not found." >&2
    exit 127
fi

tmp_out="$(mktemp)"
tmp_err="$(mktemp)"
tmp_combined="$(mktemp)"
scan_input_file="$(mktemp)"
normalized_output_file=""
compact_output_file=""
stream_file="${CLAUDE_STREAM_FILE:-}"
auto_stream_file="false"
if [[ -z "${stream_file}" ]]; then
    stream_file="$(mktemp "${TMPDIR:-/tmp}/claude-cross-check-stream.XXXXXX")"
    auto_stream_file="true"
else
    mkdir -p "$(dirname "${stream_file}")"
    : > "${stream_file}"
fi

cleanup() {
    rm -f "${tmp_out}" "${tmp_err}" "${tmp_combined}" "${scan_input_file}" "${normalized_output_file}" "${compact_output_file}"
    if [[ "${auto_stream_file}" == "true" ]]; then
        rm -f "${stream_file}"
    fi
}
trap cleanup EXIT

{
    echo "=== Claude cross-check stream start $(date '+%Y-%m-%d %H:%M:%S %z') ==="
    echo "prompt: ${user_prompt}"
    echo
} >> "${stream_file}"
echo "Streaming Claude output to: ${stream_file}" >&2

build_prompt() {
    local mode="$1"
    local branch
    local changed_files
    local cwd

    cwd="$(pwd)"
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    changed_files="$(git status --short 2>/dev/null | head -n 20 || true)"
    if [[ -z "${changed_files}" ]]; then
        changed_files="(clean or unavailable)"
    fi

    if [[ "${mode}" == "compact" ]]; then
        cat <<EOF
You are a fast cross-check assistant for Codex.

Task:
${user_prompt}

Reply with exactly 3 bullets:
- recommendation
- main risk
- next step

Max 80 words.
EOF
        return 0
    fi

    cat <<EOF
You are assisting Codex with a quick cross-check. Give concrete, short output.

Task:
${user_prompt}

Repository context:
- cwd: ${cwd}
- branch: ${branch}
- changed files (first 20):
${changed_files}

Output format:
1) Recommended direction (max 3 bullets)
2) Key risks (max 5 bullets)
3) Missing context (exact files/questions, or "none")
4) Next actions for Codex (numbered, max 5)

Keep the whole answer under 180 words.
EOF
}

run_claude_with_timeout() {
    local timeout="$1"
    local prompt="$2"
    local output_file="$3"
    local error_file="$4"
    local started
    local claude_pid
    local -a cmd
    local out_offset=0
    local err_offset=0

    append_stream_delta() {
        local source_file="$1"
        local previous_offset="$2"
        local label="$3"
        local current_size
        local added_bytes

        current_size="$(wc -c < "${source_file}" | tr -d '[:space:]')"
        if (( current_size > previous_offset )); then
            added_bytes=$((current_size - previous_offset))
            {
                echo
                echo "--- ${label} +${added_bytes} bytes @ $(date '+%H:%M:%S') ---"
                tail -c "+$((previous_offset + 1))" "${source_file}"
            } >> "${stream_file}"
            echo "${current_size}"
            return 0
        fi

        echo "${previous_offset}"
    }

    cmd=(claude -p --output-format text)
    cmd+=("${prompt}")

    "${cmd[@]}" >"${output_file}" 2>"${error_file}" &
    claude_pid=$!
    started=$(date +%s)

    while kill -0 "${claude_pid}" 2>/dev/null; do
        out_offset="$(append_stream_delta "${output_file}" "${out_offset}" "stdout")"
        err_offset="$(append_stream_delta "${error_file}" "${err_offset}" "stderr")"

        if (( $(date +%s) - started >= timeout )); then
            kill "${claude_pid}" 2>/dev/null || true
            sleep 1
            kill -9 "${claude_pid}" 2>/dev/null || true
            wait "${claude_pid}" 2>/dev/null || true

            out_offset="$(append_stream_delta "${output_file}" "${out_offset}" "stdout")"
            err_offset="$(append_stream_delta "${error_file}" "${err_offset}" "stderr")"
            echo "--- timeout after ${timeout}s ---" >> "${stream_file}"
            return 124
        fi
        sleep 1
    done

    out_offset="$(append_stream_delta "${output_file}" "${out_offset}" "stdout")"
    err_offset="$(append_stream_delta "${error_file}" "${err_offset}" "stderr")"
    echo "--- process exited normally ---" >> "${stream_file}"

    wait "${claude_pid}"
    return $?
}

attempt=1
attempts_used=0
claude_exit=0
run_status="failed"
prompt_mode="full"

while (( attempt <= max_attempts )); do
    attempts_used=$attempt
    prompt_to_send="$(build_prompt "${prompt_mode}")"
    if run_claude_with_timeout "${timeout_seconds}" "${prompt_to_send}" "${tmp_out}" "${tmp_err}"; then
        claude_exit=0
        run_status="ok"
        break
    else
        claude_exit=$?
    fi

    if [[ "${claude_exit}" -eq 124 ]]; then
        run_status="timed_out"
    else
        run_status="failed"
    fi

    if (( attempt < max_attempts )); then
        # Retry with a shorter prompt to avoid long waits in degraded conditions.
        prompt_mode="compact"
        : > "${tmp_out}"
        : > "${tmp_err}"
    fi

    attempt=$((attempt + 1))
done

cat "${tmp_out}" "${tmp_err}" > "${tmp_combined}"
risk_level="none"
blocked="false"
risk_reason=""
scan_truncated="false"

combined_size="$(wc -c < "${tmp_combined}" | tr -d '[:space:]')"
if (( combined_size > scan_max_bytes )); then
    head -c "${scan_max_bytes}" "${tmp_combined}" > "${scan_input_file}"
    scan_truncated="true"
else
    cp "${tmp_combined}" "${scan_input_file}"
fi

normalized_output_file="$(mktemp)"
compact_output_file="$(mktemp)"

# Normalize for risk scanning: lowercase + strip quoting noise + collapse whitespace.
tr '[:upper:]' '[:lower:]' < "${scan_input_file}" \
    | sed -E "s/[\`'\\\"]/ /g" \
    | tr -s '[:space:]' ' ' \
    > "${normalized_output_file}"

# Compact form catches split-token obfuscation like: r m -rf
tr '[:upper:]' '[:lower:]' < "${scan_input_file}" \
    | sed -E "s/[\`'\\\"]//g" \
    | tr -d '[:space:]' \
    > "${compact_output_file}"

declare -a risk_patterns=(
    "rm[[:space:]]+-rf"
    "git[[:space:]]+reset[[:space:]]+--hard"
    "git[[:space:]]+clean[[:space:]]+-fdx"
    "curl[^\\n]*\\|[[:space:]]*(bash|sh)"
    "wget[^\\n]*\\|[[:space:]]*(bash|sh)"
    "(^|[^[:alnum:]_])sudo[[:space:]]+[[:alnum:]_./-]+"
    "drop[[:space:]]+database"
    "(^|[^[:alnum:]_])(mkfs|fdisk)([[:space:]]|$)"
    "(^|[^[:alnum:]_])dd[[:space:]]+(if|of)="
)

for pattern in "${risk_patterns[@]}"; do
    if grep -Eiq "${pattern}" "${normalized_output_file}"; then
        blocked="true"
        risk_level="blocked"
        risk_reason="Matched risky pattern: ${pattern}"
        break
    fi
done

if [[ "${blocked}" != "true" ]]; then
    # Secondary checks on compact text for simple whitespace-obfuscated commands.
    declare -a compact_risk_patterns=(
        "(^|[^a-z0-9_])rm-rf(/|[^a-z0-9_]|$)"
        "(^|[^a-z0-9_])gitreset--hard([^a-z0-9_]|$)"
        "(^|[^a-z0-9_])gitclean-fdx([^a-z0-9_]|$)"
        "curl.*\\|(bash|sh)"
        "wget.*\\|(bash|sh)"
        "(^|[^a-z0-9_])dropdatabase([^a-z0-9_]|$)"
        "(^|[^a-z0-9_])(mkfs|fdisk)([^a-z0-9_]|$)"
    )

    for pattern in "${compact_risk_patterns[@]}"; do
        if grep -Eiq "${pattern}" "${compact_output_file}"; then
            blocked="true"
            risk_level="blocked"
            risk_reason="Matched compact risky pattern: ${pattern}"
            break
        fi
    done
fi

if [[ "${blocked}" == "true" ]]; then
    echo "Blocked Claude suggestion due to risky content. Do not execute the suggested command." >&2
    exit 2
fi

if [[ "${run_status}" != "ok" ]]; then
    if [[ "${run_status}" == "timed_out" ]]; then
        echo "Claude cross-check timed out after ${timeout_seconds}s. Try a shorter prompt or raise CLAUDE_TIMEOUT_SECONDS." >&2
        exit 124
    fi

    echo "Claude cross-check failed (exit ${claude_exit})." >&2
    exit "${claude_exit}"
fi

cat "${tmp_out}"
exit 0
