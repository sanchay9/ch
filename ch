#!/bin/bash

PORT=10043

NC='\033[0m'
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'

if [ "$1" = "-h" ] || [ "$1" = "--help" ] || [ "$1" = "help" ]; then
    echo -e "Usage: $(basename "$0") <command> [arguments]\n"

    echo "Commands:"
    echo "  samples      - run samples"
    echo "  run          - run with custom input"
    echo "  interact     - run in interactive mode"
    echo "  stress       - Run stress tests"
    echo "  validate     - Returns test on which validator doesn't return OK"
    echo "  clean        - Clean up files for a specific problem"
    echo "  receive      - Start a TCP server to receive requests"
    exit 0
fi

compile() {
    cmd="g++ -std=c++20 -O2 -DLOCAL -Wall -Wextra -Wshadow -Wconversion -Wfloat-equal -Wduplicated-cond -Wlogical-op -D_GLIBCXX_DEBUG -fsanitize=undefined -fno-sanitize-recover -o ${1} ${1}.cpp"
    # cmd="gum spin --spinner minidot --show-output --title Compiling -- $cmd"

    if ! $cmd; then
        echo -e "${RED}failed to compile ${1}.cpp${NC}"
        exit 1
    fi
}

run_samples() {
    if ! ls "${1}_input"* >/dev/null 2>&1; then
        echo -e "${RED}no input files, try ch receive${NC}"
        exit 1
    fi

    input_files=("${1}_input"*)
    expected_files=("${1}_expected"*)

    if [ ${#input_files[@]} -ne ${#expected_files[@]} ]; then
        echo -e "${RED}Error: Mismatched number of input and expected output files.${NC}"
        exit 1
    fi

    num_tests=${#input_files[@]}

    all_tests_passed=0
    for ((j = 1; j <= num_tests; j++)); do
        input="${input_files[$j - 1]}"
        expected="${expected_files[$j - 1]}"
        output="${1}_output_${j}"

        ./"$1" <"$input" &>"$output"

        # if cmp -s "$file1" "$file2"; then
        if diff -q "$expected" "$output" >/dev/null; then
            echo -e "${BLUE}Test $j: ✅${NC}"
            all_tests_passed=$((all_tests_passed + 1))
        else
            echo -e "${BLUE}Test $j: ❌${NC}"
        fi
        diff -y --color "$expected" "$output"
        printf "\n"
        # delta -s "$expected" "$output"
        # kitty +kitten diff "$expected" "$output"
    done

    if [ "$all_tests_passed" = "$num_tests" ]; then
        echo -e "${GREEN}All tests passed!!${NC}"
    else
        echo -e "${RED}Samples Failed :(${NC}"
    fi
}

process_req() {
    req=$1
    json=$(echo "$req" | sed '1,/^\x0d/d')
    # json=$(echo "$req" | awk '/\{/,/\}/')

    # contest_dir=$(gum input --prompt "Enter Directory Name: " --placeholder ".")
    # mkdir "$contest_dir"
    # cd "$contest_dir" || exit 1

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

if [ "$1" = "process" ]; then
    process_req "$(tee)"
elif [ "$1" = "samples" ]; then
    compile "$2"
    run_samples "$2"
elif [ "$1" = "run" ]; then
    compile "$2"
    ./"$2" <~/code/input &>~/code/output
elif [ "$1" = "interact" ]; then
    compile "$2"
    echo -e "${YELLOW}Start Interaction${NC}"
    ./"$2"
elif [ "$1" = "stress" ]; then
    compile "$2"
    compile "$2"_gen
    compile "$2"_slow

    for ((i = 0; i < 100; i++)); do
        ./"$2"_gen >"$2"_input_gen
        ./"$2" <"$2"_input_gen >"$2"_output_gen
        ./"$2"_slow <"$2"_input_gen >"$2"_expected_gen

        if ! diff -q "$2"_expected_gen "$2"_output_gen >/dev/null; then
            echo -e "${CYAN}Solution Failed for test case:${NC}"
            cat "$2"_input_gen
            echo -e "${RED}Wrong Output:${NC}"
            cat "$2"_output_gen
            echo -e "${GREEN}Slow Output:${NC}"
            cat "$2"_expected_gen
            exit 1
        fi
    done

    echo -e "${GREEN}Passed some 100 random tests${NC}"
elif [ "$1" = "validate" ]; then
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
elif [ "$1" = "clean" ]; then
    if [ $# -ne 2 ]; then
        echo -e "usage: ch clean a"
        exit 1
    fi

    if ! eza --icons --oneline --color=auto "$2"*; then
        echo -e "${RED}no files to delete${NC}"
        exit 0
    fi

    echo -e "${RED}delete these files?${NC}"
    read -r -p "[y/N] " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        rm -f "$2"*
        echo -e "\n${GREEN}Done cleanup for $2${NC}"
    fi
elif [ "$1" = "receive" ]; then
    socat -u tcp-l:$PORT,reuseaddr,fork system:"ch process" &
    pid=$!

    echo -e "${PURPLE}Press ESC to quit${NC}"
    while read -s -r -n1 key; do
        if [ "$key" = "$(printf '\033')" ]; then
            kill "$pid"
            exit 0
        fi
    done
fi
