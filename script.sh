#!/usr/bin/env bash

rm -f *.md *.txt *.json

my_dir="$(pwd)"

for folder in "workflow-system"; do
    claude_dir="$(wslpath 'C:\Users\HauHau\Claude\'"$folder")"
    pushd "$claude_dir" > /dev/null || continue
    outfile="$my_dir/$folder.json"

    echo "{" > "$outfile"
    first=true

    # -z outputs null-delimited paths to safely handle spaces or special characters
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        [ "$first" = true ] && first=false || echo "," >> "$outfile"

        b64=$(base64 -w 0 "$f")
        # Use "$f" directly instead of "$(basename "$f")" to keep the relative folder path
        printf '  "%s": "%s"' "$f" "$b64" >> "$outfile"
    done < <(git ls-files | grep -vPie '^(?:\.git|\.claude)|\.(?:ps1|png)$')

    echo -e "\n}" >> "$outfile"
    echo "Packed into $outfile"

    popd > /dev/null
done
