#!/bin/bash

SCRIPT_NAME=$(basename "$0")

PORT=10043
NC='\033[0m'
UBLACK='\033[4;30m'
BLACK='\033[0;30m'
BRED='\033[1;31m'
BGREEN='\033[1;32m'
ON_GREEN='\033[42m'
ON_RED='\033[41m'
ON_WHITE='\033[47m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'

command -v jq &>/dev/null || {
    echo "error: jq not found!"
    exit 1
}

command -v socat &>/dev/null || {
    echo "error: socat not found!"
    exit 1
}

compile() {
    local source_file="$1.cpp"
    local output_file="${HOME}/code/bin/$1"

    if [[ ! -f "$source_file" ]]; then
        echo -e "\n${BLACK}${ON_RED} file not found: ${source_file} ${NC}\n"
        return 1
    fi

    g++ -std=c++20 \
        -I"${HOME}/code/include" \
        -DLOCAL \
        -D_GLIBCXX_DEBUG \
        -O2 -Wall -Wextra -Wshadow -Wconversion -Wfloat-equal -Wduplicated-cond -Wlogical-op -Wshift-overflow=2 \
        -o "$output_file" "$source_file"

    if [[ $? -ne 0 ]]; then
        echo -e "\n${BLACK}${ON_RED} failed to compile ${source_file} ${NC}\n"
        exit 1
    fi
}

run_samples() {
    input_files=()
    expected_files=()

    for i in $(seq 1 1 10); do
        if [ -f "${1}_input_${i}" ] && [ -f "${1}_expected_${i}" ]; then
            input_files+=("${1}_input_${i}")
            expected_files+=("${1}_expected_${i}")
        fi
    done

    if [ ${#input_files[@]} -eq 0 ]; then
        echo -e "\n${BLACK}${ON_RED} no test files, try ${SCRIPT_NAME} get ${NC}\n"
        exit 1
    fi

    if [ ${#input_files[@]} -ne ${#expected_files[@]} ]; then
        echo -e "\n${BLACK}${ON_RED} error: mismatched number of test files ${NC}\n"
        exit 1
    fi

    compile "$1"

    num_tests=${#input_files[@]}

    for ((j = 1; j <= num_tests; j++)); do
        input="${input_files[$j - 1]}"
        expected="${expected_files[$j - 1]}"
        output="${1}_output_${j}"

        ~/code/bin/"$1" <"$input" >"$output" 2>&1

        echo ''
        if cmp -s "$expected" "$output"; then
            echo -e "${BLACK}${ON_GREEN} Test #$j: Passed ${NC}"
        else
            echo -e "${BLACK}${ON_RED} Test #$j: Failed ${NC}"
            echo -e "${BLUE}input:${NC}"
            cat "$input"
            echo -e "${BLUE}expected:${NC}"
            cat "$expected"
            echo -e "${BLUE}output:${NC}"
            cat "$output"
        fi
    done
    rm "$output"

    echo ''
}

process_req() {
    req=$1
    json=$(echo "$req" | sed '1,/^\x0d/d')

    full=$(echo "$json" | jq -r '.name')
    echo -e "${GREEN}Parsed Problem: ${full}${NC}"
    name=$(echo "$full" | cut -c1 | awk '{print tolower($0)}')

    index=1
    tests=$(echo "$json" | jq -r '.tests')
    echo "$tests" | jq -c '.[]' | while read -r test; do
        input=$(echo "$test" | jq -r '.input')
        echo "$input" >"${name}_input_${index}"
        expected=$(echo "$test" | jq -r '.output')
        echo "$expected" >"${name}_expected_${index}"
        index=$((index + 1))
    done
    touch "${name}.cpp"
    echo -e "${GREEN}Files Prepared for ${name}${NC}"
}

reload_nvim() {
    nvim --server "$1" --remote-send "<cmd>checktime<cr>" >/dev/null &
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ] || [ "$1" = "h" ] || [ "$1" = "help" ]; then
    echo -e "Usage: $(basename "$0") <command> [arguments]\n"

    echo "Commands:"
    echo "  samples      - run samples"
    echo "  run          - run with custom input"
    echo "  interact     - run in interactive mode"
    echo "  stress       - Run stress tests"
    echo "  validate     - Returns test on which validator doesn't return OK"
    echo "  get          - Start a TCP server to receive requests"
    exit 0
fi

case "$1" in
"process")
    process_req "$(tee)"
    ;;
"samples")
    run_samples "$2"

    if [ -n "$3" ]; then
        reload_nvim "$3"
    fi
    ;;
"run")
    compile "$2"

    input_file=~/code/bin/input
    output_file=~/code/bin/output
    if [[ ! -f "$input_file" ]] || [[ ! -f "$output_file" ]]; then
        touch ~/code/bin/input ~/code/bin/output
    fi
    ~/code/bin/"$2" <$input_file >$output_file
    echo -e "\n${BLACK}${ON_GREEN} run success ${NC}\n"

    if [ -n "$3" ]; then
        reload_nvim "$3"
    fi
    ;;
"interact")
    compile "$2"
    echo -e "${YELLOW}Start Interaction${NC}"
    ./"$2"
    ;;
"stress")
    compile "$2"
    compile "$2"_gen
    compile "$2"_slow

    for ((i = 0; i < 100; i++)); do
        ./"$2"_gen >"$2"_input_gen
        ./"$2" <"$2"_input_gen >"$2"_output_gen
        ./"$2"_slow <"$2"_input_gen >"$2"_expected_gen

        if ! cmp -s "$2"_expected_gen "$2"_output_gen; then
            echo -e "\n${CYAN}Solution Failed for test case:${NC}"
            cat "$2"_input_gen
            echo -e "\n${GREEN}Slow Output:${NC}"
            cat "$2"_expected_gen
            echo -e "\n${RED}Wrong Output:${NC}"
            cat "$2"_output_gen
            exit 1
        fi
    done

    echo -e "${GREEN}Passed some 100 random tests 󰡕 ${NC}"
    ;;
"validate")
    compile "$2"
    compile "$2"_gen
    compile "$2"_val

    for ((i = 0; i < 100; i++)); do
        ./"$2"_gen >"$2"_input_gen
        ./"$2" <"$2"_input_gen >"$2"_output_val
        cat "$2"_input_gen "$2"_output_val >"$2"_expected_val
        tmp=$(./"$2"_val <"$2"_expected_val)

        if [ "${tmp:0:2}" != "OK" ]; then
            echo "$tmp"
            echo -e "${CYAN}Solution Failed for test case:${NC}"
            cat "$2"_input_gen
            echo -e "${RED}Wrong Output:${NC}"
            cat "$2"_output_val
            echo -e "${GREEN}Validator Output:${NC}"
            echo "$tmp"
            exit 1
        fi
    done

    echo -e "${GREEN}Passed some 100 random tests${NC}"
    ;;
"get")
    socat -u tcp-l:$PORT,reuseaddr,fork system:"${SCRIPT_NAME} process" &
    pid=$!

    echo -e "${PURPLE}Press ESC to quit${NC}"
    while read -s -r -n1 key; do
        if [ "$key" = "$(printf '\033')" ]; then
            kill "$pid"
            exit 0
        fi
    done
    ;;
*)
    echo "Unknown command: $command"
    ;;
esac
