#!/bin/bash

SCRIPT_NAME=$(basename "$0")

export PORT=10043
export PROCESSED="/tmp/ch"
echo 0 >"$PROCESSED"

ITERS=100
TMP_DIR=./tmp
# TMP_DIR=$(mktemp -d)

# Cleanup temporary files on exit
# trap "rm -rf $TMP_DIR" EXIT

export NC='\033[0m'
export UBLACK='\033[4;30m'
export BLACK='\033[0;30m'
export BRED='\033[1;31m'
export BGREEN='\033[1;32m'
export ON_GREEN='\033[42m'
export ON_RED='\033[41m'
export ON_BLUE='\033[44m'
export ON_WHITE='\033[47m'
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export CYAN='\033[0;36m'
export WHITE='\033[0;37m'

throw_err() {
    echo -e "\n${BLACK}${ON_RED} error: ${1} ${NC}\n"
    exit 1
}

for cmd in jq socat; do
    command -v "$cmd" &>/dev/null || {
        throw_err "command not found: ${cmd}"
    }
done

compile() {
    local source_file="$1.cpp"
    local output_file="${HOME}/code/bin/${1}"

    if [[ ! -f "$source_file" ]]; then
        throw_err "file not found: ${source_file}"
    fi

    g++ -std=c++20 \
        -I"${HOME}/code/include" \
        -DLOCAL \
        -D_GLIBCXX_DEBUG \
        -O2 -Wall -Wextra -Wshadow -Wconversion -Wfloat-equal -Wduplicated-cond -Wlogical-op -Wshift-overflow=2 \
        "$source_file"

    if [[ $? -ne 0 ]]; then
        throw_err "failed to compile ${source_file}"
    fi
}

run_samples() {
    target="${1%.cpp}"
    problem_id=$(echo "$target" | cut -c1 | awk '{print tolower($0)}')
    if [ ! -f ".${problem_id}_samples.json" ]; then
        throw_err "no samples file found, try ${SCRIPT_NAME} get"
    fi

    compile "$target"

    index=1
    jq -c '.[]' ".${problem_id}_samples.json" | while read -r test; do
        input_file="${target}_input_tmp"
        expected_file="${target}_expected_tmp"
        output_file="${target}_output_tmp"

        echo "$test" | jq -j '.input' >"$input_file"
        echo "$test" | jq -j '.output' >"$expected_file"

        ./a.out <"$input_file" >"$output_file"

        if cmp -s "$expected_file" "$output_file"; then
            echo -e "\n${BLACK}${ON_GREEN} Test #$index: Passed ${NC}"
        else
            echo -e "\n${BLACK}${ON_BLUE}input:${NC}"
            cat "$input_file"
            echo -e "${BLACK}${ON_BLUE}expected:${NC}"
            cat "$expected_file"
            echo -e "${BLACK}${ON_BLUE}output:${NC}"
            cat "$output_file"
            echo -e "\n${BLACK}${ON_RED} Test #$index: Failed ${NC}"
        fi

        rm "$input_file" "$expected_file" "$output_file"
        index=$((index + 1))
    done

    rm a.out
    echo ''
}

process_req() {
    req="$(tee)"
    json=$(echo "$req" | sed '1,/^\x0d/d')

    name=$(echo "$json" | jq -r '.name')
    echo -e "${GREEN}Parsed Problem: ${name}${NC}" >&2
    group=$(echo "$json" | jq -r '.group')

    if [ "$group" == "CSES - CSES Problem Set" ]; then
        name=$(echo "$name" | tr ' ' '_')
    else
        name=$(echo "$name" | cut -c1 | awk '{print tolower($0)}')
    fi

    if [ -f ".${name}_samples.json" ]; then
        echo -e "${YELLOW}Samples for problem ${name} already exist, skipping...${NC}" >&2
        return
    fi

    echo "$json" | jq '.tests' >".${name}_samples.json"
    if [ "$(echo "$json" | jq -r '.testType')" = "single" ]; then
        cp ~/code/template/templatesingle.cpp "${name}.cpp"
    else
        cp ~/code/template/templatemulti.cpp "${name}.cpp"
    fi

    (
        flock -x 200

        count=$(cat "$PROCESSED")
        count=$((count + 1))
        echo "$count" >"$PROCESSED"

        batch_size=$(echo "$json" | jq -r '.batch.size')
        if [ "$count" -eq "$batch_size" ]; then
            lsof -ti :"$PORT" | xargs kill
            return
        fi
    ) 200>"$PROCESSED.lock"

}
export -f process_req

reload_nvim() {
    nvim --server "$1" --remote-send '<cmd>checktime<cr>' >/dev/null &
}

case "$1" in
"precompile")
    if [[ "$(uname)" == "Darwin" ]]; then
        FILE="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1/bits/stdc++.h"
        sudo mkdir -p "$(dirname "$FILE")"
        curl -L "https://raw.githubusercontent.com/tekfyl/bits-stdc-.h-for-mac/refs/heads/master/stdc%2B%2B.h" | sudo tee "$FILE" >/dev/null
    elif [[ "$(uname)" == "Linux" ]]; then
        FILE=$(find /usr/include/c++/*/x86_64-pc-linux-gnu/bits/stdc++.h)
        if [ "$(echo "$FILE" | wc -l)" -ne 1 ]; then
            throw_err "could not find stdc++.h file"
        fi
    fi
    sudo g++ -std=c++20 \
        -DLOCAL \
        -D_GLIBCXX_DEBUG \
        -O2 -Wall -Wextra -Wshadow -Wconversion -Wfloat-equal -Wduplicated-cond -Wlogical-op -Wshift-overflow=2 \
        "$FILE"
    ;;
"samples")
    if [ -z "$2" ]; then
        throw_err "problem name not provided"
    fi

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
        touch "$input_file" "$output_file"
    fi
    ./a.out <$input_file >$output_file
    echo -e "\n${BLACK}${ON_GREEN} run success ${NC}\n"

    if [ -n "$3" ]; then
        reload_nvim "$3"
    fi
    ;;
"interact")
    compile "$2"
    echo -e "${YELLOW}Start Interaction${NC}"
    ./a.out
    ;;
"stress")
    compile "$2"
    mv a.out "$TMP_DIR/$2"
    compile "$2"_gen
    mv a.out "$TMP_DIR/$2"_gen
    compile "$2"_slow
    mv a.out "$TMP_DIR/$2"_slow

    for ((i = 1; i <= ITERS; i++)); do
        "$TMP_DIR/${2}_gen" >"$TMP_DIR/input_$i"
        "$TMP_DIR/${2}" <"$TMP_DIR/input_$i" >"$TMP_DIR/out_sol_$i"
        "$TMP_DIR/${2}_slow" <"$TMP_DIR/input_$i" >"$TMP_DIR/out_slow_$i"

        if ! cmp -s "$TMP_DIR/out_sol_$i" "$TMP_DIR/out_slow_$i"; then
            echo -e "\n${RED}FAILED on test $i${NC}"
            echo -e "${CYAN}--- Input ---${NC}"
            cat "$TMP_DIR/input_$i"
            echo -e "\n${GREEN}--- Expected (Slow) ---${NC}"
            cat "$TMP_DIR/out_slow_$i"
            echo -e "\n${RED}--- Found (Solution) ---${NC}"
            cat "$TMP_DIR/out_sol_$i"

            exit 1
        fi

        printf "\r${GREEN}Passed test: %d/%d${NC}" "$i" "$ITERS"
    done

    echo -e "\n\n${GREEN}Successfully passed all $ITERS tests! 󰡕 ${NC}"
    ;;
"validate")
    compile "$2"
    mv a.out "$2"
    compile "$2"_gen
    mv a.out "$2"_gen
    compile "$2"_val
    mv a.out "$2"_val

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
    echo -e "${GREEN}Listening on port $PORT${NC}\n"
    socat -lf /dev/null tcp-l:$PORT,reuseaddr,fork system:"process_req"
    ;;
*)
    echo -e "Usage: $SCRIPT_NAME <command> [arguments]\n"

    echo "Commands:"
    echo "  samples      - run samples"
    echo "  run          - run with custom input"
    echo "  interact     - run in interactive mode"
    echo "  stress       - Run stress tests"
    echo "  validate     - Returns test on which validator doesn't return OK"
    echo "  get          - Start a TCP server to receive requests"
    exit 0
    ;;
esac
