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
#   ./get-okta-token.sh [--refresh]
#
#   You will be prompted interactively for your username and password
#   (the password input is hidden). Pass --refresh to print the refresh
#   token instead of the access token.
#
# Configuration (edit the variables below if the environment changes):
#   OKTA_URL         Base URL of the Okta authorization server.
#   SCOPE            Space-separated OAuth scopes to request.
#   OKTA_CLIENT_ID   Client ID of the registered Okta application.
#
# Output:
#   On success:  "Token: <access_token>" (or "Refresh: <refresh_token>"
#                with --refresh) is written to stdout.
#   On failure:  an error message followed by the raw JSON response.
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

WANT_REFRESH=false
if [ "$1" = "--refresh" ]; then
  WANT_REFRESH=true
fi

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

if [ -z "$token" ]; then
  echo "Failed to authenticate, check below error"
  echo "$result"
  exit 1
fi

if [ "$WANT_REFRESH" = true ]; then
  refresh_token=$(echo "$result" | jq -r '.refresh_token // empty')
  if [ -z "$refresh_token" ]; then
    echo "No refresh_token in response, check below"
    echo "$result"
    exit 1
  fi
  echo "Refresh: $refresh_token"
else
  echo "Token: $token"
fi
