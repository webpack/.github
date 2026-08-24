#!/bin/bash


# usage: ./org-workflows-on-main.sh

ORG="webpack"

# Colors (disabled when not writing to a terminal)
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; RED=""; YELLOW=""; CYAN=""
fi

# Check if logged into GitHub CLI
gh auth status || exit 1

# List all repositories in the organization, with their default branch
repos=$(gh repo list "$ORG" --limit 100 --json name,defaultBranchRef \
    --jq '.[] | "\(.name)\t\(.defaultBranchRef.name // "")"')

failed=()
ok=0

while IFS=$'\t' read -r repo branch; do
    [ -n "$repo" ] || continue

    # Empty repository: no default branch to check
    if [ -z "$branch" ]; then
        printf '%s•%s %-40s %s%-8s%s %s%s%s\n' \
            "$YELLOW" "$RESET" "$ORG/$repo" \
            "$YELLOW" "empty" "$RESET" \
            "$DIM" "no default branch" "$RESET"
        continue
    fi

    # Date of the last commit pushed to the default branch
    updated=$(gh api "repos/$ORG/$repo/commits/$branch" 2>/dev/null | jq -r '.commit.committer.date // empty')

    # Legacy commit statuses
    status_json=$(gh api "repos/$ORG/$repo/commits/$branch/status" 2>/dev/null)
    s_count=0; s_state=""
    if [ -n "$status_json" ]; then
        s_count=$(jq -r '.total_count // 0' <<< "$status_json")
        s_state=$(jq -r '.state // empty' <<< "$status_json")
    fi

    # Workflow / check runs (GitHub Actions and other check-run apps)
    checks_json=$(gh api "repos/$ORG/$repo/commits/$branch/check-runs" 2>/dev/null)
    c_count=0; c_state=""
    if [ -n "$checks_json" ]; then
        c_count=$(jq -r '.total_count // 0' <<< "$checks_json")
        c_state=$(jq -r '
            (.check_runs // []) as $r
            | if ($r | length) == 0 then ""
              elif [$r[] | select(.status != "completed")] | length > 0 then "pending"
              elif [$r[] | select(.conclusion == "failure")] | length > 0 then "failure"
              else "success" end' <<< "$checks_json")
    fi

    if [ -z "$status_json" ] && [ -z "$checks_json" ]; then
        # Nothing to report on at all (e.g. branch not reachable)
        state="success"
        label="null"
    elif [ "$s_count" -eq 0 ] && [ "$c_count" -eq 0 ]; then
        # No status checks and no workflow runs -> considered successful
        state="success"
        label="success"
    elif [ "$s_state" = "failure" ] || [ "$s_state" = "error" ] || [ "$c_state" = "failure" ]; then
        state="failure"
        label="failure"
    elif { [ "$s_count" -gt 0 ] && [ "$s_state" = "pending" ]; } || [ "$c_state" = "pending" ]; then
        state="pending"
        label="pending"
    else
        state="success"
        label="success"
    fi

    # 2026-08-20T14:33:02Z -> 2026-08-20 14:33 UTC
    if [ -n "$updated" ]; then
        when="${updated//T/ }"
        when="last push to $branch ${when%:*Z} UTC"
    else
        when="no commits on $branch"
    fi

    case "$state" in
        success)
            ok=$((ok + 1))
            color="$GREEN"; mark="✔"
            ;;
        failure|error)
            failed+=("https://github.com/$ORG/$repo/commits/$branch")
            color="$RED"; mark="✖"
            ;;
        *)
            color="$YELLOW"; mark="•"
            ;;
    esac

    printf '%s%s%s %-40s %s%-8s%s %s%s%s\n' \
        "$color" "$mark" "$RESET" "$ORG/$repo" \
        "$color" "$label" "$RESET" \
        "$DIM" "$when" "$RESET"
done <<< "$repos"

echo ""
if [ ${#failed[@]} -eq 0 ]; then
    printf '%s%s✔ All %d repositories are green on their default branch%s\n' "$BOLD" "$GREEN" "$ok" "$RESET"
else
    printf '%s%s✖ %d failing repositor%s%s\n' "$BOLD" "$RED" "${#failed[@]}" \
        "$([ ${#failed[@]} -eq 1 ] && echo y || echo ies)" "$RESET"
    for url in "${failed[@]}"; do
        printf '  %s%s%s\n' "$CYAN" "$url" "$RESET"
    done
    printf '%s%d passing%s\n' "$DIM" "$ok" "$RESET"
fi
