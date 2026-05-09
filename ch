#!/bin/bash
#
# ch
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME

readonly PORT="10043"
readonly CODE_DIR="${HOME}/code"
readonly TEMPLATE_DIR="${CODE_DIR}/template"
readonly INCLUDE_DIR="${CODE_DIR}/include"

readonly PROCESSED="/tmp/ch_processed_$$"

readonly ITERS=100

readonly SOLUTION_SUFFIXES=(dfs bfs iterative recursive brute greedy dp)

# Create temp directory and ensure cleanup
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ch.XXXXXX")
trap 'cleanup' EXIT INT TERM

cleanup() {
    rm -rf "$TMP_DIR"
    rm -f "$PROCESSED" "$PROCESSED.lock"
}

NC='\033[0m'
BLACK='\033[0;30m'
ON_GREEN='\033[42m'
ON_RED='\033[41m'
ON_BLUE='\033[44m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'

export NC BLACK ON_GREEN ON_RED ON_BLUE GREEN YELLOW CYAN
export PORT PROCESSED TEMPLATE_DIR

COMMON_FLAGS="-std=c++23 -DLOCAL -D_GLIBCXX_DEBUG -O2 -Wall -Wextra -Wshadow -Wconversion -Wfloat-equal"
if g++ --version 2>&1 | grep -q "GCC"; then
    COMMON_FLAGS+=" -Wduplicated-cond -Wlogical-op -Wshift-overflow=2"
fi
readonly COMMON_FLAGS

throw_err() {
    echo -e "\n${BLACK}${ON_RED} error: ${1} ${NC}\n" >&2
    exit 1
}

log_info() {
    echo -e "${GREEN}$1${NC}" >&2
}

check_dependencies() {
    local missing=()
    for cmd in jq socat g++; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        throw_err "missing required commands: ${missing[*]}"
    fi
}

check_dependencies

compile() {
    local name="$1"
    local source_file="${name}.cpp"

    if [[ ! -f "$source_file" ]]; then
        throw_err "file not found: ${source_file}"
    fi

    # shellcheck disable=SC2086
    if ! g++ $COMMON_FLAGS -I"$INCLUDE_DIR" "$source_file" -o a.out; then
        throw_err "failed to compile ${source_file}"
    fi
}

run_samples() {
    local target="${1%.cpp}"
    local problem="$target"
    if [[ "$target" == *_* ]]; then
        local suffix="${target##*_}"
        for allowed in "${SOLUTION_SUFFIXES[@]}"; do
            if [[ "$suffix" == "$allowed" ]]; then
                problem="${target%_*}"
                break
            fi
        done
    fi
    local metadata_file=".${problem}.json"

    if [[ ! -f "$metadata_file" ]]; then
        throw_err "no metadata file found, try ${SCRIPT_NAME} get"
    fi

    compile "$target"

    local index=1
    local passed=0
    local failed=0
    local input_file="$TMP_DIR/input"
    local expected_file="$TMP_DIR/expected"
    local output_file="$TMP_DIR/output"

    while read -r test; do
        printf '%s' "$test" | jq -j '.input' >"$input_file"
        printf '%s' "$test" | jq -j '.output' >"$expected_file"

        if ! ./a.out <"$input_file" >"$output_file" 2>&1; then
            echo -e "${BLACK}${ON_RED} Test #$index: Runtime Error ${NC}"
            ((failed++)) || true
        elif cmp -s "$expected_file" "$output_file" >/dev/null; then
            echo -e "${BLACK}${ON_GREEN} Test #$index: Passed ${NC}"
            ((passed++)) || true
        else
            echo -e "${BLACK}${ON_RED} Test #$index: Failed ${NC}"
            echo -e "${BLACK}${ON_BLUE}input:${NC}"
            cat "$input_file"
            echo -e "${BLACK}${ON_BLUE}expected:${NC}"
            cat "$expected_file"
            echo -e "${BLACK}${ON_BLUE}output:${NC}"
            cat "$output_file"
            ((failed++)) || true
        fi
        printf '\n'

        ((index++)) || true
    done < <(jq -c '.tests[]' "$metadata_file")

    rm -f a.out
}

process_req() {
    local json name group test_type batch_size

    json=$(cat | sed '1,/^\x0d/d')

    name=$(printf '%s' "$json" | jq -r '.name')
    if [[ -z "$name" ]]; then
        echo -e "${YELLOW}Warning: Could not parse problem name${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}Parsed Problem: ${name}${NC}" >&2
    group=$(printf '%s' "$json" | jq -r '.group // empty')

    if [[ "$group" == "CSES - CSES Problem Set" ]]; then
        name=$(echo "$name" | tr ' ' '_')
    else
        name=$(echo "$name" | grep -oE '^[A-Za-z][0-9]*' | tr '[:upper:]' '[:lower:]')
    fi

    local metadata_file=".${name}.json"
    if [[ -f "$metadata_file" ]]; then
        echo -e "${YELLOW}Metadata for problem ${name} already exists, backing up...${NC}" >&2
        mv "$metadata_file" "${metadata_file}.bak"
    fi
    printf '%s' "$json" >"$metadata_file"
    jq 'del(.batch, .languages)' "$metadata_file" >"${metadata_file}.tmp" && mv "${metadata_file}.tmp" "$metadata_file"

    if [[ -f "${name}.cpp" ]]; then
        echo -e "${YELLOW}Solution file ${name}.cpp already exists, backing up...${NC}" >&2
        mv "${name}.cpp" "${name}.cpp.bak" 2>/dev/null
    fi
    test_type=$(printf '%s' "$json" | jq -r '.testType // "multi"')
    if [[ "$test_type" == "single" ]]; then
        cp "${TEMPLATE_DIR}/single.cpp" "${name}.cpp"
    else
        cp "${TEMPLATE_DIR}/multi.cpp" "${name}.cpp"
    fi

    # Handle batch processing with proper locking
    (
        flock -x 200

        local count=0
        [[ -f "$PROCESSED" ]] && count=$(cat "$PROCESSED")
        count=$((count + 1))
        echo "$count" >"$PROCESSED"

        batch_size=$(printf '%s' "$json" | jq -r '.batch.size // 1')
        if [[ "$count" -eq "$batch_size" ]]; then
            # Gracefully stop the server
            local pids
            pids=$(lsof -ti :"$PORT" 2>/dev/null || true)
            if [[ -n "$pids" ]]; then
                echo "$pids" | xargs -r kill 2>/dev/null || true
            fi
        fi
    ) 200>"$PROCESSED.lock"
}
export -f process_req

reload_nvim() {
    local server="$1"
    if [[ -n "$server" ]] && command -v nvim &>/dev/null; then
        nvim --server "$server" --remote-send '<cmd>checktime<cr>' >/dev/null 2>&1 &
    fi
}

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME <command> [arguments]

Commands:
  samples <file> [nvim_server]   Run sample test cases for a problem
  run <file> [nvim_server]       Run solution with custom input/output files
  interact <file>                Run solution in interactive mode
  stress <file>                  Run stress tests (requires <file>_gen.cpp, <file>_slow.cpp)
  validate <file>                Run validation tests (requires <file>_gen.cpp, <file>_val.cpp)
  get                            Start TCP server to receive problems from browser extension
  precompile                     Precompile stdc++.h for faster compilation

Examples:
  $SCRIPT_NAME samples a           # Run samples for problem 'a'
  $SCRIPT_NAME run solution        # Run 'solution.cpp' with input file
  $SCRIPT_NAME stress b            # Stress test 'b.cpp' against 'b_slow.cpp'
  $SCRIPT_NAME get                 # Listen for problems from Competitive Companion
EOF
}

cmd_precompile() {
    local file

    if [[ "$(uname)" == "Darwin" ]]; then
        file="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1/bits/stdc++.h"
        if [[ ! -f "$file" ]]; then
            log_info "Downloading stdc++.h for macOS..."
            sudo mkdir -p "$(dirname "$file")"
            if ! curl -fsSL "https://raw.githubusercontent.com/tekfyl/bits-stdc-.h-for-mac/refs/heads/master/stdc%2B%2B.h" | sudo tee "$file" >/dev/null; then
                throw_err "failed to download stdc++.h"
            fi
        fi
    elif [[ "$(uname)" == "Linux" ]]; then
        file=$(find /usr/include/c++/*/x86_64-pc-linux-gnu/bits/stdc++.h 2>/dev/null | head -1)
        if [ "$(echo "$file" | wc -l)" -ne 1 ]; then
            throw_err "could not find stdc++.h file"
        fi
    else
        throw_err "unsupported operating system: $(uname)"
    fi

    log_info "Precompiling $file..."
    # shellcheck disable=SC2086
    sudo g++ $COMMON_FLAGS "$file"
    log_info "Precompilation complete!"
}

cmd_samples() {
    local file="${1:-}"
    local nvim_server="${2:-}"

    if [[ -z "$file" ]]; then
        throw_err "problem name not provided. Usage: $SCRIPT_NAME samples <file>"
    fi

    run_samples "$file"
    reload_nvim "$nvim_server"
}

cmd_run() {
    local file="${1:-}"
    local nvim_server="${2:-}"

    if [[ -z "$file" ]]; then
        throw_err "file name not provided. Usage: $SCRIPT_NAME run <file>"
    fi

    compile "$file"

    local input_file="${CODE_DIR}/bin/input"
    local output_file="${CODE_DIR}/bin/output"

    mkdir -p "${CODE_DIR}/bin"
    touch "$input_file" "$output_file"

    if ./a.out <"$input_file" >"$output_file"; then
        echo -e "\n${BLACK}${ON_GREEN} run success ${NC}\n"
    else
        echo -e "\n${BLACK}${ON_RED} run failed (exit code: $?) ${NC}\n"
    fi

    rm -f a.out
    reload_nvim "$nvim_server"
}

cmd_interact() {
    local file="${1:-}"

    if [[ -z "$file" ]]; then
        throw_err "file name not provided. Usage: $SCRIPT_NAME interact <file>"
    fi

    compile "$file"
    echo -e "${YELLOW}Starting Interactive Mode (Ctrl+D to exit)${NC}"
    ./a.out
    rm -f a.out
}

cmd_stress() {
    local file="${1:-}"

    if [[ -z "$file" ]]; then
        throw_err "file name not provided. Usage: $SCRIPT_NAME stress <file>"
    fi

    for suffix in "" "_gen" "_slow"; do
        if [[ ! -f "${file}${suffix}.cpp" ]]; then
            throw_err "required file not found: ${file}${suffix}.cpp"
        fi
    done

    compile "$file"
    mv a.out "$TMP_DIR/${file}"

    compile "${file}_gen"
    mv a.out "$TMP_DIR/${file}_gen"

    compile "${file}_slow"
    mv a.out "$TMP_DIR/${file}_slow"

    local input_file="$TMP_DIR/input"
    local sol_output="$TMP_DIR/sol_output"
    local slow_output="$TMP_DIR/slow_output"

    for ((i = 1; i <= ITERS; i++)); do
        "$TMP_DIR/${file}_gen" >"$input_file"
        "$TMP_DIR/${file}" <"$input_file" >"$sol_output"
        "$TMP_DIR/${file}_slow" <"$input_file" >"$slow_output"

        if ! cmp -s "$sol_output" "$slow_output"; then
            echo -e "\n${RED}FAILED on test $i${NC}"
            echo -e "${CYAN}--- Input ---${NC}"
            cat "$input_file"
            echo -e "\n${GREEN}--- Expected (Slow) ---${NC}"
            cat "$slow_output"
            echo -e "\n${RED}--- Found (Solution) ---${NC}"
            cat "$sol_output"
            exit 1
        fi

        printf "\r${GREEN}Passed test: %d/%d${NC}" "$i" "$ITERS"
    done

    echo -e "\n\n${GREEN}Successfully passed all $ITERS tests!${NC}"
}

cmd_validate() {
    local file="${1:-}"

    if [[ -z "$file" ]]; then
        throw_err "file name not provided. Usage: $SCRIPT_NAME validate <file>"
    fi

    # Verify all required files exist
    for suffix in "" "_gen" "_val"; do
        if [[ ! -f "${file}${suffix}.cpp" ]]; then
            throw_err "required file not found: ${file}${suffix}.cpp"
        fi
    done

    # Compile all programs to temp directory
    compile "$file"
    mv a.out "$TMP_DIR/${file}"

    compile "${file}_gen"
    mv a.out "$TMP_DIR/${file}_gen"

    compile "${file}_val"
    mv a.out "$TMP_DIR/${file}_val"

    local input_file="$TMP_DIR/input"
    local output_file="$TMP_DIR/output"
    local combined_file="$TMP_DIR/combined"

    for ((i = 1; i <= ITERS; i++)); do
        "$TMP_DIR/${file}_gen" >"$input_file"
        "$TMP_DIR/${file}" <"$input_file" >"$output_file"
        cat "$input_file" "$output_file" >"$combined_file"

        local result
        result=$("$TMP_DIR/${file}_val" <"$combined_file" 2>&1) || true

        if [[ "${result:0:2}" != "OK" ]]; then
            echo -e "\n${RED}FAILED on test $i${NC}"
            echo -e "${CYAN}--- Input ---${NC}"
            cat "$input_file"
            echo -e "${RED}--- Output ---${NC}"
            cat "$output_file"
            echo -e "${GREEN}--- Validator Result ---${NC}"
            echo "$result"
            exit 1
        fi

        printf "\r${GREEN}Passed test: %d/100${NC}" "$i"
    done

    echo -e "\n\n${GREEN}Successfully passed all 100 validation tests!${NC}"
}

cmd_get() {
    # Initialize processed counter
    echo 0 >"$PROCESSED"

    log_info "Listening on port $PORT for Competitive Companion..."
    echo -e "${YELLOW}Open a problem in your browser with Competitive Companion extension${NC}\n"

    socat -lf /dev/null "tcp-l:$PORT,reuseaddr,fork" system:"process_req"
}

main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
    precompile) cmd_precompile "$@" ;;
    samples) cmd_samples "$@" ;;
    run) cmd_run "$@" ;;
    interact) cmd_interact "$@" ;;
    stress) cmd_stress "$@" ;;
    validate) cmd_validate "$@" ;;
    get) cmd_get "$@" ;;
    help | -h | --help)
        show_help
        exit 0
        ;;
    "")
        show_help
        exit 0
        ;;
    *)
        echo -e "${RED}Unknown command: $cmd${NC}\n" >&2
        show_help
        exit 1
        ;;
    esac
}

main "$@"
