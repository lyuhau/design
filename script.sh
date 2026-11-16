#!/usr/bin/env bash

rm design.md

claude_dir="$(wslpath 'C:\Users\HauHau\Claude\workflow-platform')"
pushd "$claude_dir"
git ls-files | grep -vPie '^(?:\.git|\.claude)|(?:\.ps1)$' \
| while read f; do
	echo "===\n$f\n==="
	cat "$f"
done >design.md
popd

mv "$claude_dir/design.md" .

