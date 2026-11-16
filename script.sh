#!/usr/bin/env bash

rm *.txt

my_dir="$(pwd)"

for f in workflow-system workflow-system-v1; do
    claude_dir="$(wslpath 'C:\Users\HauHau\Claude\'"$f")"
    pushd "$claude_dir"

    git ls-files | grep -vPie '^(?:\.git|\.claude)|(?:\.ps1|\.png|\.ico)$' \
    | while read f; do
        echo "===\n$f\n==="
        cat "$f"
    done >"$my_dir/$f.txt"

    popd
done
