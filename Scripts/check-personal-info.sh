#!/bin/bash
# Looks for personal information in this repository before you push.
#
#   Scripts/check-personal-info.sh            the tracked files and the staged changes
#   Scripts/check-personal-info.sh --history  also every commit on every local branch
#   Scripts/check-personal-info.sh --strict   also fail on the general shapes (point 2)
#
# Two kinds of check:
#
# 1. Your own values. Put one value on each line of a file outside the repository:
#    ~/.config/sill/private-patterns.txt (or set SILL_PRIVATE_PATTERNS to another path).
#    Good values to list: your real name, your email addresses, your Mac's name, your
#    Tailscale address and MagicDNS name, your tailnet name, your Apple team ID and your
#    bundle ID. Each line is a fixed string, not a pattern. Lines that start with # are
#    comments. The script never prints the file.
#
# 2. General shapes: email addresses that are not noreply or example ones, Tailscale
#    addresses that are not the documented examples, MagicDNS names, home folder paths,
#    and the files that must stay untracked (Packaging/Local.xcconfig, tailscale.conf,
#    provisioning profiles, keys).
#
# Point 1 and the untracked files make it fail. Point 2 only lists lines to review, because the
# test fixtures and the upstream history hold many example values; --strict makes it fail too.
# It reads files only. It changes nothing. It exits 1 when it finds something, else 0.
# No pipefail: "git log | grep -q" stops early, and git then exits with SIGPIPE.
set -u
cd "$(dirname "$0")/.."

history=0; strict=0
for arg in "$@"; do
    case "$arg" in
        --history) history=1 ;;
        --strict) strict=1 ;;
        *) echo "usage: $0 [--history] [--strict]" >&2; exit 2 ;;
    esac
done
found=0; review=0
say() { printf '%s\n' "$*"; }
hit() { found=1; say "FOUND: $*"; }
# A general shape: listed for review; a failure only with --strict.
shape() { review=$((review + 1)); if [ "$strict" = 1 ]; then hit "$*"; else say "REVIEW: $*"; fi; }

# The documented examples and test fixtures, which are allowed. A range ("100.64.0.0/10") is skipped.
allowed_ips='^100\.(64\.[0-9.]+|72\.[0-9.]+|84\.3\.2|88\.123\.45|100\.100\.100|101\.[0-9.]+|127\.255\.255)$'
allowed_mail='(noreply|no-reply|example\.(com|org|net)|users\.noreply\.github\.com|anthropic\.com|getsill\.app)'

# Files that must never be tracked.
for f in Packaging/Local.xcconfig tailscale.conf; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then hit "$f is tracked; it must stay local"; fi
done
if git ls-files | grep -Eq '\.(provisionprofile|mobileprovision|p12|p8|pem|keychain|keychain-db)$'; then
    hit "a key, certificate or profile file is tracked: $(git ls-files | grep -E '\.(provisionprofile|mobileprovision|p12|p8|pem|keychain|keychain-db)$' | head -3 | tr '\n' ' ')"
fi

# What to search: the tracked tree, the staged changes, and with --history every commit.
search() {
    # $1: a git grep pattern (extended), printed matches as "where:line".
    git grep -I -n -E -e "$1" -- . ':!Scripts/check-personal-info.sh' 2>/dev/null
    git diff --cached -U0 | grep -E '^\+' | grep -E -e "$1" | sed 's/^/staged: /'
    if [ "$history" = 1 ]; then
        git log --all -p --no-color -U0 | grep -E '^\+' | grep -E -e "$1" | sed 's/^/history: /'
    fi
}

# 1. Your own values.
patterns="${SILL_PRIVATE_PATTERNS:-$HOME/.config/sill/private-patterns.txt}"
if [ -f "$patterns" ]; then
    n=0
    while IFS= read -r value || [ -n "$value" ]; do
        case "$value" in ""|\#*) continue ;; esac
        n=$((n + 1))
        if git grep -I -q -F -e "$value" -- . ':!Scripts/check-personal-info.sh' 2>/dev/null; then
            hit "private value number $n is in the tracked files: $(git grep -I -l -F -e "$value" -- . | head -3 | tr '\n' ' ')"
        fi
        if git diff --cached | grep -q -F -e "$value"; then hit "private value number $n is in the staged changes"; fi
        if [ "$history" = 1 ] && git log --all -p --no-color | grep -q -F -e "$value"; then
            hit "private value number $n is in the history: git log --all -S'<value>' finds the commits"
        fi
        if git log --all --format='%an %ae %cn %ce' | grep -q -F -e "$value"; then
            hit "private value number $n is in a commit's author or committer"
        fi
    done < "$patterns"
    say "Checked $n private values from $patterns."
else
    say "No private values file at $patterns: only the general shapes are checked."
fi

# 2. General shapes.
while IFS= read -r line; do
    for mail in $(printf '%s' "$line" | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'); do
        # "background@2x.png" and the like are file names, not addresses.
        printf '%s' "$mail" | grep -Eq '\.(png|jpg|jpeg|pdf|svg|tiff|icns|swift|json|plist)$' && continue
        printf '%s' "$mail" | grep -Eq "$allowed_mail" || shape "an email address: $line"
    done
done < <(search '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')

while IFS= read -r line; do
    for ip in $(printf '%s' "$line" | grep -oE '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]+)?'); do
        case "$ip" in */*) continue ;; esac
        printf '%s' "$ip" | grep -Eq "$allowed_ips" || shape "a Tailscale address: $line"
    done
done < <(search '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b')

while IFS= read -r line; do
    printf '%s' "$line" | grep -Eq '(tail1234|example|tailnet-name)\.ts\.net' || shape "a MagicDNS name: $line"
done < <(search '[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.ts\.net')

while IFS= read -r line; do
    printf '%s' "$line" | grep -Eq '/Users/(you|me|name|USER|\$USER|<[a-z]+>|Shared)\b' || shape "a home folder path: $line"
done < <(search '/Users/[A-Za-z0-9._-]+')

for who in "$(git config user.email 2>/dev/null)"; do
    [ -z "$who" ] && continue
    printf '%s' "$who" | grep -Eq "$allowed_mail" && continue
    if git log --all --format='%ae %ce' | grep -q -F -e "$who"; then
        hit "your git email ($who) is on a commit; use a GitHub noreply address"
    fi
done

[ "$review" -gt 0 ] && say "$review lines to review (examples and fixtures are expected)."
if [ "$found" = 0 ]; then say "Nothing found that fails the check."; exit 0; fi
say "Review each line above before you push."
exit 1
