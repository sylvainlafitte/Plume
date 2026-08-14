#!/bin/bash
# Spike C — how much memory does context actually cost?
#
# Phase 4 assumes num_ctx: 8192 fits alongside gemma4 in a ~10.7 GiB Metal working set.
# The KV-cache cost had a ~10x predicted spread depending on sliding-window handling.
#
# Method: for each context size — fully unload, verify nothing is resident, load via
# /api/chat with an empty `messages` array (a pure load op), verify `ollama ps` reports
# the CONTEXT we asked for, then read resident SIZE once it has settled.
#
# The CONTEXT column (ollama 0.32+) is what makes this trustworthy: it confirms the
# option was actually applied rather than silently ignored.

set -uo pipefail
cd "$(dirname "$0")"

MODEL="${1:-gemma4:latest}"
HOST="http://127.0.0.1:11434"

# `ollama ps` columns: NAME ID SIZE UNIT PROCESSOR% "GPU" CONTEXT UNTIL...
#   gemma4:latest  c6eb...  9.5  GB  100%  GPU  8192  4 minutes from now
ps_row() { ollama ps 2>/dev/null | awk -v m="$MODEL" '$1==m'; }
ps_size() { ps_row | awk '{print $3" "$4}'; }
ps_proc() { ps_row | awk '{print $5" "$6}'; }
ps_ctx() { ps_row | awk '{print $7}'; }

wait_unloaded() {
    for _ in $(seq 1 40); do
        [ -z "$(ps_row)" ] && return 0
        sleep 0.5
    done
    return 1
}

# Wait for SIZE to be non-empty and identical twice in a row.
wait_settled() {
    local prev="" cur=""
    for _ in $(seq 1 60); do
        cur="$(ps_size)"
        if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then return 0; fi
        prev="$cur"
        sleep 0.5
    done
    return 1
}

if ! curl -s --max-time 5 "$HOST/api/tags" > /dev/null 2>&1; then
    echo "❌ Ollama not reachable at $HOST."
    echo "   The daemon is not always running — Ollama.app starts it lazily."
    echo "   Wake it with: ollama list"
    exit 1
fi

echo "── Spike C · KV-cache cost for $MODEL ──"
echo "ollama   : $(ollama --version 2>/dev/null | tail -1)"
echo "RAM      : $(( $(sysctl -n hw.memsize) / 1073741824 )) GB   ($(sysctl -n hw.model))"
echo "on disk  : $(ollama list 2>/dev/null | awk -v m="$MODEL" '$1==m {print $3" "$4}')"
echo

printf '%-9s %-12s %-10s %-11s %s\n' "num_ctx" "resident" "reported" "processor" "load"
printf '%-9s %-12s %-10s %-11s %s\n' "-------" "--------" "--------" "---------" "----"

declare -a rows
for ctx in 4096 8192 16384 32768 65536; do
    curl -s "$HOST/api/chat" \
        -d "{\"model\":\"$MODEL\",\"messages\":[],\"keep_alive\":0}" > /dev/null 2>&1
    if ! wait_unloaded; then
        echo "  (warning: model still resident before num_ctx=$ctx — reading may be unreliable)"
    fi

    start=$(date +%s)
    body=$(curl -s --max-time 300 "$HOST/api/chat" -d "{
        \"model\":\"$MODEL\",
        \"messages\":[],
        \"keep_alive\":\"5m\",
        \"options\":{\"num_ctx\":$ctx}
    }" 2>&1)
    elapsed=$(( $(date +%s) - start ))

    if ! wait_settled; then
        err=$(printf '%s' "$body" | head -c 120)
        printf '%-9s %-12s %-10s %-11s %s\n' "$ctx" "DID NOT LOAD" "—" "—" "${elapsed}s"
        rows+=("$ctx|**did not load**|—|—|${elapsed}s|$err")
        continue
    fi

    size="$(ps_size)"; reported="$(ps_ctx)"; proc="$(ps_proc)"
    flag=""
    [ "$reported" != "$ctx" ] && flag="  ⚠️ requested $ctx, got $reported"
    printf '%-9s %-12s %-10s %-11s %ss%s\n' "$ctx" "$size" "$reported" "$proc" "$elapsed" "$flag"
    rows+=("$ctx|$size|$reported|$proc|${elapsed}s|")
done

curl -s "$HOST/api/chat" -d "{\"model\":\"$MODEL\",\"messages\":[],\"keep_alive\":0}" >/dev/null 2>&1
wait_unloaded
echo
echo "unloaded."

{
    echo "# Spike C — KV-cache cost"
    echo
    echo "**Date:** $(date +%Y-%m-%d) · **Model:** \`$MODEL\` ($(ollama list 2>/dev/null | awk -v m="$MODEL" '$1==m {print $3" "$4}') on disk)"
    echo "**Host:** $(sysctl -n hw.model), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion), ollama $(ollama --version 2>/dev/null | tail -1 | sed 's/.*version is //')"
    echo
    echo "Measured by \`measure.sh\`: full unload → verify nothing resident → load with an empty"
    echo "\`messages\` array → verify \`ollama ps\` reports the requested CONTEXT → read resident"
    echo "SIZE once stable across two consecutive polls."
    echo
    echo "| num_ctx requested | resident size | context reported | processor | load time |"
    echo "|---|---|---|---|---|"
    for r in "${rows[@]}"; do
        IFS='|' read -r a b c d e f <<< "$r"
        echo "| $a | $b | $c | $d | $e |"
    done
    echo
} > RESULTS.md
echo "▸ wrote RESULTS.md"
