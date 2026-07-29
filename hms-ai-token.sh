#!/usr/bin/env bash
# =============================================================================
# hms-ai-token.sh
#
# WHAT THIS DOES
#   Logs in to HMS (Okta) for you and prints an access token. An access token
#   is a temporary password that lets your tools talk to the HMS AI service.
#   Tokens expire after a while, so this script exists to fetch a new one
#   whenever it's needed — you run it (or Claude Code runs it for you) and it
#   prints a fresh token.
#
# HOW TO GIVE IT YOUR LOGIN
#   Pick ONE of these two options:
#
#   Option 1 - Refresh token (recommended, no password needed):
#       mkdir -p ~/.claude
#       umask 077; ./get-okta-token.sh --refresh \
#         | awk -F'Refresh: ' '/Refresh:/{print $2}' > ~/.claude/.hms_refresh_token
#     A refresh token is a long-lived key you get once (see the README, step 1).
#     It lets the script renew your access without your password.
#
#     As a convenience you may instead export it once:
#         export HMS_REFRESH_TOKEN="paste-your-refresh-token-here"
#     The script uses that only to bootstrap — on the first successful login it
#     writes the token to the file above and uses the file from then on. See
#     "WHY THE FILE MATTERS" below; do NOT rely on the variable alone.
#
#   Option 2 - Username and password:
#       export HMS_USERNAME="your-hms-id"
#       export HMS_PASSWORD="your-password"
#     Also used automatically as a fallback if the refresh token stops working.
#
#   Tip: put whichever "export" lines you choose in your shell profile
#   (e.g. ~/.bashrc or ~/.zshrc), or better, store them in a password manager.
#   Never type your real password directly into this file.
#
# WHY THE FILE MATTERS (read this if you ever saw "refresh token is invalid")
#   Okta rotates refresh tokens: every time this script spends one, Okta issues
#   a replacement and retires the old one seconds later. A refresh token is
#   therefore single-use, so it cannot live in an environment variable — a
#   script cannot change its parent shell's variables, so the next run would
#   replay a token Okta has already retired and the login would fail. Instead
#   this script keeps the current token in a file it owns and rewrites that file
#   after every login. A lock serialises concurrent runs (Claude Code may
#   invoke this script several times at once) so two logins never race and
#   invalidate each other's token.
#
# WHERE THE TOKEN IS STORED
#   ~/.claude/.hms_refresh_token  (mode 600, created automatically)
#   Override with HMS_REFRESH_TOKEN_FILE=/path/to/file if you prefer elsewhere.
#
# HOW TO RUN IT
#       ./hms-ai-token.sh
#   It prints just the token to stdout, nothing else, so it works both when you
#   run it yourself and when Claude Code calls it automatically. Everything
#   else — warnings, errors — goes to stderr.
# =============================================================================

# Stop immediately if anything goes wrong, so we never print a broken token.
set -euo pipefail

# --- HMS / Okta settings (you should not need to change these) ---------------
OKTA_URL="https://login.hms.harvard.edu"
AUTH_SERVER="aus155lzzptyDTgN3698"
CLIENT_ID="0oa139tiylzbW6XnX698"
SCOPE="openid offline_access"
TOKEN_ENDPOINT="$OKTA_URL/oauth2/$AUTH_SERVER/v1/token"

# --- Where we keep the current refresh token ---------------------------------
REFRESH_FILE="${HMS_REFRESH_TOKEN_FILE:-$HOME/.claude/.hms_refresh_token}"
LOCK_DIR="$REFRESH_FILE.lock"
LOCK_WAIT_SECONDS=30   # how long to wait for another run to finish
LOCK_STALE_MINUTES=2   # after this, assume a crashed run left the lock behind

# Print an error message and exit. Errors go to the screen (stderr), never mixed
# in with the token, so a tool reading the token never sees them by mistake.
die() { echo "hms-ai-token: $*" >&2; exit 1; }
warn() { echo "hms-ai-token: $*" >&2; }

# --- Make sure the tools we rely on are installed ----------------------------
command -v curl >/dev/null || die "the 'curl' program is required but not installed"
command -v jq   >/dev/null || die "the 'jq' program is required but not installed"

# --- Lock, so two simultaneous runs don't spend the same refresh token -------
# 'mkdir' either creates the directory or fails, atomically, on every platform —
# which is exactly the "only one winner" behaviour a lock needs.
have_lock=false
release_lock() {
  if [[ "$have_lock" == true ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    have_lock=false
  fi
}

acquire_lock() {
  mkdir -p -- "$(dirname -- "$REFRESH_FILE")" \
    || die "could not create $(dirname -- "$REFRESH_FILE") to store the refresh token"
  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # A lock older than LOCK_STALE_MINUTES belongs to a run that died; clear it.
    if find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null | grep -q .; then
      warn "clearing a stale lock left behind by an earlier run"
      rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    sleep 1
    waited=$((waited + 1))
    if (( waited >= LOCK_WAIT_SECONDS )); then
      die "timed out waiting for another token refresh to finish. If nothing else is running, remove $LOCK_DIR"
    fi
  done
  have_lock=true
  trap release_lock EXIT INT TERM
}

# --- Read / write the stored refresh token -----------------------------------
read_stored_refresh() {
  [[ -s "$REFRESH_FILE" ]] || return 0
  # Strip any whitespace, so a stray newline from 'echo >' can't corrupt it.
  tr -d '[:space:]' < "$REFRESH_FILE"
}

save_refresh() {
  local value="$1" tmp
  tmp="$(mktemp -- "$REFRESH_FILE.XXXXXX")" \
    || die "could not write to $(dirname -- "$REFRESH_FILE")"
  chmod 600 -- "$tmp"
  printf '%s\n' "$value" > "$tmp"
  # Rename, rather than overwrite in place, so the file is never half-written.
  mv -f -- "$tmp" "$REFRESH_FILE"
}

# --- Ask Okta for a token ----------------------------------------------------
# Extra login arguments are passed in; --data-urlencode escapes the values, so
# passwords and tokens containing '&', '+' or '%' are sent correctly.
okta_post() {
  curl --silent --show-error --request POST \
    --url "$TOKEN_ENDPOINT" \
    --header "Accept: application/json" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "scope=$SCOPE" \
    "$@"
}

# Okta's explanation for a rejected login, if it gave one.
okta_error() {
  jq -r '[.error, .error_description] | map(select(. != null)) | join(": ")' <<<"$1" 2>/dev/null
}

acquire_lock

# --- Decide how to log in, based on what you provided ------------------------
# The file wins over the variable: it holds the token Okta most recently issued,
# whereas the variable still holds whatever was exported at login time.
refresh_token="$(read_stored_refresh)"
refresh_source="$REFRESH_FILE"
if [[ -z "$refresh_token" && -n "${HMS_REFRESH_TOKEN:-}" ]]; then
  refresh_token="$HMS_REFRESH_TOKEN"
  refresh_source="\$HMS_REFRESH_TOKEN"
fi

have_password_login=false
if [[ -n "${HMS_USERNAME:-}" && -n "${HMS_PASSWORD:-}" ]]; then
  have_password_login=true
fi

if [[ -z "$refresh_token" && "$have_password_login" == false ]]; then
  die "no login details found. Store a refresh token in $REFRESH_FILE, or set both HMS_USERNAME and HMS_PASSWORD (see the notes at the top of this script)"
fi

access_token=""

# --- Attempt 1: renew using the refresh token (no password needed) -----------
if [[ -n "$refresh_token" ]]; then
  response="$(okta_post \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$refresh_token")" \
    || die "could not reach the login server. Check your internet connection or VPN"

  access_token="$(jq -r '.access_token // empty' <<<"$response")"

  if [[ -n "$access_token" ]]; then
    # THE IMPORTANT PART: keep the replacement token Okta just issued. Without
    # this, the token we spent above is retired and the next run would fail.
    rotated="$(jq -r '.refresh_token // empty' <<<"$response")"
    if [[ -n "$rotated" ]]; then
      save_refresh "$rotated"
    elif [[ ! -s "$REFRESH_FILE" ]]; then
      # This Okta app doesn't rotate; still move the token into the file so the
      # file is the single source of truth from now on.
      save_refresh "$refresh_token"
    fi
  else
    reason="$(okta_error "$response")"
    if [[ "$have_password_login" == true ]]; then
      warn "the stored refresh token was rejected${reason:+ ($reason)}; falling back to HMS_USERNAME/HMS_PASSWORD"
    else
      die "the refresh token in $refresh_source was rejected${reason:+ ($reason)}. Get a new one with 'get-okta-token.sh --refresh' and store it in $REFRESH_FILE, or set HMS_USERNAME and HMS_PASSWORD as a fallback"
    fi
  fi
fi

# --- Attempt 2: log in with username and password ----------------------------
if [[ -z "$access_token" ]]; then
  response="$(okta_post \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=$HMS_USERNAME" \
    --data-urlencode "password=$HMS_PASSWORD")" \
    || die "could not reach the login server. Check your internet connection or VPN"

  access_token="$(jq -r '.access_token // empty' <<<"$response")"
  if [[ -z "$access_token" ]]; then
    # No token means the login was rejected. Show Okta's explanation if there is
    # one, without dumping the whole reply (which can contain sensitive details).
    reason="$(okta_error "$response")"
    die "login failed${reason:+ ($reason)}. Double-check your credentials"
  fi

  # A password login also yields a fresh refresh token — store it, so subsequent
  # runs are password-free again.
  rotated="$(jq -r '.refresh_token // empty' <<<"$response")"
  if [[ -n "$rotated" ]]; then
    save_refresh "$rotated"
  fi
fi

# Success: print ONLY the token.
printf '%s\n' "$access_token"
