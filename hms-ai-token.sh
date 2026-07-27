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
#   The script does NOT ask you to type your password each time. Instead, you
#   provide your login details once, as "environment variables", and the script
#   reads them. Pick ONE of these two options:
#
#   Option 1 - Refresh token (recommended, no password needed):
#       export HMS_REFRESH_TOKEN="paste-your-refresh-token-here"
#     A refresh token is a long-lived key you get once (see the README, step 1).
#     It lets the script renew your access without your password.
#
#   Option 2 - Username and password:
#       export HMS_USERNAME="your-hms-id"
#       export HMS_PASSWORD="your-password"
#
#   Tip: put whichever "export" lines you choose in your shell profile
#   (e.g. ~/.bashrc or ~/.zshrc), or better, store them in a password manager.
#   Never type your real password directly into this file.
#
# HOW TO RUN IT
#       ./hms-ai-token.sh
#   It prints just the token, nothing else, so it works both when you run it
#   yourself and when Claude Code calls it automatically.
# =============================================================================

# Stop immediately if anything goes wrong, so we never print a broken token.
set -euo pipefail

# --- HMS / Okta settings (you should not need to change these) ---------------
OKTA_URL="https://login.hms.harvard.edu"
AUTH_SERVER="aus155lzzptyDTgN3698"
CLIENT_ID="0oa139tiylzbW6XnX698"
SCOPE="openid offline_access"
TOKEN_ENDPOINT="$OKTA_URL/oauth2/$AUTH_SERVER/v1/token"

# Print an error message and exit. Errors go to the screen (stderr), never mixed
# in with the token, so a tool reading the token never sees them by mistake.
die() { echo "hms-ai-token: $*" >&2; exit 1; }

# --- Make sure the tools we rely on are installed ----------------------------
command -v curl >/dev/null || die "the 'curl' program is required but not installed"
command -v jq   >/dev/null || die "the 'jq' program is required but not installed"

# --- Decide how to log in, based on what you provided ------------------------
# We assemble the extra pieces of the login request into the 'login' array.
declare -a login
if [[ -n "${HMS_REFRESH_TOKEN:-}" ]]; then
  # Option 1: renew using the refresh token (no password needed).
  login=(--data "grant_type=refresh_token"
         --data "refresh_token=$HMS_REFRESH_TOKEN")
elif [[ -n "${HMS_USERNAME:-}" && -n "${HMS_PASSWORD:-}" ]]; then
  # Option 2: log in with username and password.
  login=(--data "grant_type=password"
         --data "username=$HMS_USERNAME"
         --data "password=$HMS_PASSWORD")
else
  die "no login details found. Set HMS_REFRESH_TOKEN, or set both HMS_USERNAME and HMS_PASSWORD (see the notes at the top of this script)"
fi

# --- Ask Okta for a token ----------------------------------------------------
response="$(curl --silent --show-error --request POST \
  --url "$TOKEN_ENDPOINT" \
  --header "Accept: application/json" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "client_id=$CLIENT_ID" \
  --data "scope=$SCOPE" \
  "${login[@]}")" || die "could not reach the login server. Check your internet connection or VPN"

# --- Pull the token out of Okta's reply --------------------------------------
# Okta replies with a bundle of JSON; 'jq' picks out just the access token.
token="$(echo "$response" | jq -r '.access_token // empty')"

if [[ -z "$token" ]]; then
  # No token means the login was rejected. Show Okta's explanation if there is
  # one, without dumping the whole reply (which can contain sensitive details).
  reason="$(echo "$response" | jq -r '[.error, .error_description] | map(select(. != null)) | join(": ")' 2>/dev/null)"
  die "login failed${reason:+ ($reason)}. Double-check your credentials"
fi

# Success: print ONLY the token.
printf '%s\n' "$token"
