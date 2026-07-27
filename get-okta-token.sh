#!/usr/bin/env bash
#
# get-okta-token.sh — Retrieve an Okta OAuth 2.0 access token.
#
# Description:
#   Prompts for an HMS username and password, then exchanges them for an
#   OAuth 2.0 access token using Okta's Resource Owner Password (ROPC)
#   grant. On success the access token is printed; on failure the raw Okta
#   error response is printed for troubleshooting.
#
# Requirements:
#   - bash
#   - curl  (used to call the Okta token endpoint)
#   - jq    (used to parse the JSON response)
#
# Usage:
#   ./get-okta-token.sh
#
#   You will be prompted interactively for your username and password
#   (the password input is hidden). No arguments are required.
#
# Configuration (edit the variables below if the environment changes):
#   OKTA_URL         Base URL of the Okta authorization server.
#   SCOPE            Space-separated OAuth scopes to request.
#   OKTA_CLIENT_ID   Client ID of the registered Okta application.
#
# Output:
#   On success:  "Token: <access_token>"  is written to stdout; exit status 0.
#   On failure:  an error message and the raw JSON response are written to
#                stderr; exit status 1. (Writing to stderr means the error is
#                still visible when stdout is captured, e.g. VAR="$(... | ...)".)
#
# Notes:
#   - Okta returns HTTP 200 even for invalid credentials, so success is
#     determined by the presence of an access_token in the response body
#     rather than by curl's exit status.
#   - The password is read into a shell variable and sent over HTTPS to
#     Okta; it is never written to disk by this script.

OKTA_URL="https://login.hms.harvard.edu"
SCOPE="openid offline_access"
OKTA_CLIENT_ID="0oa139tiylzbW6XnX698"

read -rp "Enter Username: " USER_NAME
read -rsp "Password: " PASSWORD
echo

result=$(curl --silent --show-error --request POST \
  --url "$OKTA_URL/oauth2/aus155lzzptyDTgN3698/v1/token" \
  --header "Accept: application/json" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "client_id=$OKTA_CLIENT_ID" \
  --data "grant_type=password" \
  --data "username=$USER_NAME" \
  --data "password=$PASSWORD" \
  --data "scope=$SCOPE")


# Okta returns HTTP 200 with an error body on bad credentials, so check for the
# token itself rather than curl's exit status.
token=$(echo "$result" | jq -r '.access_token // empty')

if [ -n "$token" ]; then
  echo "Token: $token"
else
  # Write failures to stderr and exit non-zero so errors still surface when
  # stdout is captured, e.g. TOKEN="$(./get-okta-token.sh | ...)".
  echo "Failed to authenticate, check below error" >&2
  echo "$result" >&2
  exit 1
fi
