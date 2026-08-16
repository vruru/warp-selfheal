#!/usr/bin/env bash

# Require root privilege
[[ "$EUID" -ne '0' ]] && echo "Error:This script must be run as root!" && exit 1

# Help
help() {
  cat <<EOF
 Usage:
   bash api.sh
    -h/--help                  help
    -f/--file string           Configuration file (requires parameter)
    -r/--register              Register an account
    -t/--token string          Register with a team token (requires parameter)
    -d/--device                Get the devices information and plus traffic quota
    -a/--app                   Fetch App information
    -b/--bind                  Get the account blinding devices
    -n/--name string           Change the device name (requires parameter)
    -l/--license string        Change the license (requires parameter)
    -u/--unbind                Unbine a device from the account
    -c/--cancle                Cancle the account
    -i/--id                    Show the client id and reserved
    -o/--organization string   Team Organization (requires parameter)
    -e/--email string          Team Email (requires parameter)
    -m/--masque-register       Register a MASQUE account
    -s/--masque-enroll         Enroll a MASQUE account
    -g/--config string         MASQUE config file (default: config.json)
    -p/--device-name string    Set device name when registering or enrolling
    -k/--regen-key             Force regenerate key pair during enroll/update

EOF
}

# ====== MASQUE Key generation helpers ======
generate_private_key() {
  PRIVATE_KEY=$(openssl ecparam -name prime256v1 -genkey -noout -outform DER | base64 --wrap=0)
}

derive_public_key() {
  PUBLIC_KEY=$(echo "$PRIVATE_KEY" | base64 -d | \
    openssl ec -inform DER -pubout -outform DER 2>/dev/null | base64 --wrap=0)
}

generate_device_ids() {
  INSTALL_ID=$(head -c 16 /dev/urandom | base32 | awk '{print tolower(substr($0, 1, 22))}')
  FCM_TOKEN=$(head -c 16 /dev/urandom | base32 | awk '{print tolower(substr($0, 1, 22))}')
}

# ====== MASQUE Process API Response ======
process_registration_response() {
  local response=$1

  # Extract JSON fields
  ID=$(echo "$response" | python3 -m json.tool | awk -F '"' '/"id":/{print $4; exit}')

  if [ -z "$ID" ] || [ "$ID" = "null" ]; then
    echo "Error: Failed to extract ID from response" >&2
    exit 1
  fi

  LICENSE=$(echo "$response" | python3 -m json.tool | awk -F '"' '/"license":/{print $4}')
  IPV4=$(echo "$response" | python3 -m json.tool | grep -A 5 '"interface":' | awk -F '"' '/"v4":/{print $4; exit}')
  IPV6=$(echo "$response" | python3 -m json.tool | grep -A 5 '"interface":' | awk -F '"' '/"v6":/{print $4; exit}')
  ENDPOINT_V4=$(echo "$response" | python3 -m json.tool | grep -A 5 '"endpoint":' | awk -F '"' '/"v4":/{print $4; exit}' | sed -E 's/:([0-9]+)?$//')
  ENDPOINT_V6=$(echo "$response" | python3 -m json.tool | grep -A 5 '"endpoint":' | awk -F '"' '/"v6":/{print $4; exit}' | sed -E 's/^\[(.*)\]:[0-9]+$/\1/')
  ENDPOINT_PUB_KEY=$(echo "$response" | python3 -m json.tool | awk -F '"' '/"public_key":/{print $4}')

  # Build new JSON config file
  cat > "$CONFIG_FILE" <<EOF
{
  "private_key": "$PRIVATE_KEY",
  "endpoint_v4": "$ENDPOINT_V4",
  "endpoint_v6": "$ENDPOINT_V6",
  "endpoint_pub_key": "$ENDPOINT_PUB_KEY",
  "license": "$LICENSE",
  "id": "$ID",
  "access_token": "$ACCESS_TOKEN",
  "ipv4": "$IPV4",
  "ipv6": "$IPV6"
}
EOF

  echo "Config saved to $CONFIG_FILE" >&2
  cat "$CONFIG_FILE"
}

# ====== MASQUE Common logic ======
update_and_save_config() {
  local base_response=$1

  ID=$(echo "$base_response" | python3 -m json.tool | grep -m 1 '"id"' | sed -E 's/.*"id": "([^"]*)".*/\1/')
  ACCESS_TOKEN=$(echo "$base_response" | python3 -m json.tool | grep -m 1 -E '"token"|access_token' | sed -E 's/.*": "([^"]*)".*/\1/')

  # Check if enroll without forced key regeneration
  if [ "$ACTION" = "enroll" ] && [ "$REGEN_KEY" = false ] && [ -n "$PRIVATE_KEY" ]; then
    # During enroll, reuse existing PRIVATE_KEY if not forced to regenerate
    echo "Using existing private/public key pair for enrollment." >&2
    # Recalculate PUBLIC_KEY if not yet set
    if [ -z "$PUBLIC_KEY" ]; then
      derive_public_key
    fi
  else
    # Other cases (register or forced regeneration)
    if [ "$REGEN_KEY" = true ] || [ -n "$DEVICE_NAME" ]; then
      echo "Generating new key pair..." >&2
      generate_private_key
      # Recalculate public_key after regenerating private_key
      derive_public_key
    else
      # Try to get private_key from base_response if not specified
      if [ -n "$PRIVATE_KEY" ]; then
        # PRIVATE_KEY already set in enroll_account
        # Recalculate PUBLIC_KEY if not yet set
        if [ -z "$PUBLIC_KEY" ]; then
          derive_public_key
        fi
      else
        PRIVATE_KEY=$(echo "$base_response" | python3 -m json.tool | grep -m 1 '"private_key"' | sed -E 's/.*"private_key": "([^"]*)".*/\1/')
        if [ -z "$PRIVATE_KEY" ] || [ "$PRIVATE_KEY" = "null" ]; then
          echo "No existing private key found, generating new one..." >&2
          generate_private_key
        fi
        # Ensure a matching public_key in all cases
        derive_public_key
      fi
    fi
  fi

  REQUEST_DATA="{\"key\":\"$PUBLIC_KEY\",\"key_type\":\"secp256r1\",\"tunnel_type\":\"masque\""
  if [ -n "$DEVICE_NAME" ]; then
    REQUEST_DATA+=",\"name\":\"$DEVICE_NAME\""
  fi
  REQUEST_DATA+="}"

  RESPONSE=$(curl --silent --request PATCH "https://api.cloudflareclient.com/v0a4471/reg/$ID" \
    --header "User-Agent: WARP for Android" \
    --header "CF-Client-Version: a-6.35-4471" \
    --header "Content-Type: application/json; charset=UTF-8" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --data "$REQUEST_DATA")

  if ! echo "$RESPONSE" | python3 -m json.tool >/dev/null 2>&1; then
    echo "Error: API response not valid JSON" >&2
    echo "$RESPONSE" >&2; exit 1
  fi
  if echo "$RESPONSE" | python3 -m json.tool | grep -q '"error"'; then
    echo "Error during update:" >&2
    echo "$RESPONSE" | python3 -m json.tool >&2; exit 1
  fi

  # Insert access_token before warp_enabled
  FORMATTED_RESPONSE=$(echo "$RESPONSE" | python3 -m json.tool | sed "/\"warp_enabled\".*/i\    \"token\": \"$ACCESS_TOKEN\",")

  # Save to file if REGISTER_PATH is set
  if [ -n "$REGISTER_PATH" ]; then
    [ ! -d "$(dirname "$REGISTER_PATH")" ] && mkdir -p $(dirname "$REGISTER_PATH")
    echo "$FORMATTED_RESPONSE" > "$REGISTER_PATH"
    cat $REGISTER_PATH
  else
    echo "$FORMATTED_RESPONSE"
  fi
}

# ====== MASQUE Register ======
masque_register_account() {
  echo "Registering new MASQUE account..." >&2
  generate_private_key
  derive_public_key
  generate_device_ids

  RESPONSE=$(curl --silent --request POST "https://api.cloudflareclient.com/v0a4471/reg" \
    --header "Content-Type: application/json" \
    --data '{
      "key": "'"$PRIVATE_KEY"'",
      "install_id": "'"$INSTALL_ID"'",
      "fcm_token": "'"$FCM_TOKEN"'",
      "type": "Android",
      "locale": "en-US",
      "key_type": "secp256r1",
      "tunnel_type": "masque"
    }')

  if ! echo "$RESPONSE" | python3 -m json.tool >/dev/null 2>&1; then
    echo "Error: API response not valid JSON" >&2
    echo "$RESPONSE" >&2; exit 1
  fi
  if echo "$RESPONSE" | python3 -m json.tool | grep -q '"error"'; then
    echo "Error during registration:" >&2
    echo "$RESPONSE" | python3 -m json.tool >&2; exit 1
  fi

  update_and_save_config "$RESPONSE"
}

# ====== MASQUE Enroll ======
masque_enroll_account() {
  echo "Enrolling existing MASQUE account..." >&2
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found. Please register first." >&2
    exit 1
  fi

  BASE_RESPONSE=$(cat "$CONFIG_FILE")
  PRIVATE_KEY=$(echo "$BASE_RESPONSE" | awk -F '"' '/"private_key"/{print $4}')
  if [ -z "$PRIVATE_KEY" ] || [ "$PRIVATE_KEY" = "null" ]; then
    echo "Private key found in config file. Please check if it is valid." >&2
    exit 1
  fi

  # Determine if public key needs regeneration
  [ "$REGEN_KEY" = false ] && derive_public_key

  update_and_save_config "$BASE_RESPONSE"
}

# Fetch account information
fetch_account_information() {
  # If no account file, prompt for Device ID and API token
  if [ -s "$REGISTER_PATH" ]; then
    # Teams account file
    if grep -q 'xml version' $REGISTER_PATH; then
      ID=$(grep 'correlation_id' $REGISTER_PATH | sed "s#.*>\(.*\)<.*#\1#")
      TOKEN=$(grep 'warp_token' $REGISTER_PATH | sed "s#.*>\(.*\)<.*#\1#")
      CLIENT_ID=$(grep 'client_id' $REGISTER_PATH | sed "s#.*client_id&quot;:&quot;\([^&]\{4\}\)&.*#\1#")

    # Official API file, default: /etc/wireguard/warp-account.conf
    elif grep -q 'client_id' $REGISTER_PATH; then
      ID=$(awk -F '"' '/"id"/ {print $4; exit}' "$REGISTER_PATH")
      TOKEN=$(awk -F '"' '/"token"/ {print $4; exit}' "$REGISTER_PATH")
      CLIENT_ID=$(awk -F '"' '/client_id/ {print $4; exit}' "$REGISTER_PATH")

    # Client file, default: /var/lib/cloudflare-warp/reg.json
    elif grep -q 'registration_id' $REGISTER_PATH; then
      ID=$(sed 's/.*registration_id":"\([^"]\+\)".*/\1/' "$REGISTER_PATH")
      TOKEN=$(sed 's/.*api_token":"\([^"]\+\)".*/\1/' "$REGISTER_PATH")

    # wgcf file, default: /etc/wireguard/wgcf-account.toml
    elif grep -q 'access_token' $REGISTER_PATH; then
      ID=$(awk -F"'" '/device_id/ {print $2; exit}' "$REGISTER_PATH")
      TOKEN=$(awk -F"'" '/access_token/ {print $2; exit}' "$REGISTER_PATH")

    # warp-go file, default: /opt/warp-go/warp.conf
    elif grep -q 'PrivateKey' $REGISTER_PATH; then
      ID=$(awk '/^Device/ {print $NF; exit}' "$REGISTER_PATH")
      TOKEN=$(awk '/^Token/ {print $NF; exit}' "$REGISTER_PATH")

    else
      echo " There is no registered account information, please check the content. " && exit 1
    fi
  else
    read -rp " Input device id: " ID
    local i=5
    until [[ "$ID" =~ ^(t\.)?[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}$ ]]; do
      ((i--)) || true
      [ "$i" = 0 ] && echo " Input errors up to 5 times. The script is aborted. " && exit 1 || read -rp " Device id should be 36 or 38 characters, please re-enter (${i} times remaining): " ID
    done

    read -rp " Input api token: " TOKEN
    local i=5
    until [[ "$TOKEN" =~ ^[A-F0-9a-f]{8}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{4}-[A-F0-9a-f]{12}$ ]]; do
      ((i--)) || true
      [ "$i" = 0 ] && echo " Input errors up to 5 times. The script is aborted. " && exit 1 || read -rp " Api token should be 36 characters, please re-enter (${i} times remaining): " TOKEN
    done
  fi
}

# Register WARP account
register_account() {
  # Generate WireGuard key pair and append private key
  if [ -x "$(type -p wg)" ]; then
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(wg pubkey <<<"$PRIVATE_KEY")
  elif [[ -x "$(type -p openssl)" && -x "$(type -p base64)" ]]; then
    # No xxd dependency, extract key via PKCS#8 DER tail 32 bytes
    KEY_DER=$(openssl genpkey -algorithm X25519 -outform DER | base64 | tr -d '\n')
    PRIVATE_KEY=$(echo -n "$KEY_DER" | base64 -d | tail -c 32 | base64 | tr -d '\n')
    PUBLIC_KEY=$(echo -n "$KEY_DER" | base64 -d | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64 | tr -d '\n')
  elif [[ -x "$(type -p openssl)" && -x "$(type -p xxd)" && -x "$(type -p base64)" ]]; then
    KEY_PAIR=$(openssl genpkey -algorithm X25519 | openssl pkey -text -noout)
    PRIVATE_KEY=$(echo $KEY_PAIR | sed 's/.*priv:\(.*\)pub.*/\1/; s/ //g' | xxd -r -p | base64)
    PUBLIC_KEY=$(echo $KEY_PAIR | sed 's/.*pub://; s/ //g'| xxd -r -p | base64)
  else
    WG_API=$(curl -m5 -sSL "https://warp.cloudflare.now.cc/?run=key&format=yaml")
    PRIVATE_KEY=$(awk 'NR==2 {print $2}' <<<"$WG_API")
    PUBLIC_KEY=$(awk 'NR==1 {print $2}' <<<"$WG_API")
  fi

  if grep -q . <<<"$PRIVATE_KEY" && grep -q . <<<"$PUBLIC_KEY"; then
    INSTALL_ID=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)
    FCM_TOKEN="${INSTALL_ID}:APA91b$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 134)"

    # Retry registration to handle IP rate limiting
    until grep -q 'account' <<<"$ACCOUNT"; do
      [ "$ACCOUNT" = 'error code: 1015' ] && sleep 10
      ACCOUNT=$(curl --request POST 'https://api.cloudflareclient.com/v0a2158/reg' \
        --silent \
        --location \
        --tlsv1.3 \
        --header 'User-Agent: okhttp/3.12.1' \
        --header 'CF-Client-Version: a-6.10-2158' \
        --header 'Content-Type: application/json' \
        --header "Cf-Access-Jwt-Assertion: $(sed 's/.*?token=//' <<<"$TEAM_TOKEN")" \
        --data '{"key":"'${PUBLIC_KEY}'","install_id":"'${INSTALL_ID}'","fcm_token":"'${FCM_TOKEN}'","tos":"'$(date +"%Y-%m-%dT%H:%M:%S.000Z")'","model":"PC","serial_number":"'${INSTALL_ID}'","locale":"zh_CN"}')
    done

    CLIENT_ID=$(sed 's/.*"client_id":"\([^\"]\+\)\".*/\1/' <<<"$ACCOUNT")
    if [ -x "$(type -p od)" ]; then
      RESERVED=$(echo "$CLIENT_ID" | base64 -d | od -An -tu1 | awk '{print "["$1", "$2", "$3"]"}')
    else
      RESERVED=$(echo "$CLIENT_ID" | base64 -d | xxd -p | fold -w2 | while read HEX; do printf '%d ' "0x${HEX}"; done | awk '{print "["$1", "$2", "$3"]"}')
    fi

    ACCOUNT=$(python3 -m json.tool <<<"$ACCOUNT" 2>&1 | sed "/\"key\"/a\    \"private_key\": \"$PRIVATE_KEY\"," | sed "/\"client_id\"/a\        \"reserved\": $RESERVED,")
  fi

  grep -q 'error' <<<"$ACCOUNT" && echo " Failed to register an account. " && exit 1
  if [ -n "$REGISTER_PATH" ]; then
    [ ! -d "$(dirname "$REGISTER_PATH")" ] && mkdir -p $(dirname "$REGISTER_PATH")
    echo "$ACCOUNT" >$REGISTER_PATH 2>&1
    cat $REGISTER_PATH
  else
    echo "$ACCOUNT"
  fi

  exit 0
}

# Get device information
device_information() {
  [ "$#" = 2 ] && local ID="$1" && local TOKEN="$2"
  [[ -z "$ID" && -z "$TOKEN" ]] && fetch_account_information

  curl --request GET "https://api.cloudflareclient.com/v0a2158/reg/${ID}" \
    --silent \
    --location \
    --header 'User-Agent: okhttp/3.12.1' \
    --header 'CF-Client-Version: a-6.10-2158' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${TOKEN}" |
    python3 -m json.tool | sed "/\"warp_enabled\"/i\    \"token\": \"${TOKEN}\","
}

# Get app information
app_information() {
  [[ -z "$ID" && -z "$TOKEN" ]] && fetch_account_information

  curl --request GET "https://api.cloudflareclient.com/v0a2158/client_config" \
    --silent \
    --location \
    --header 'User-Agent: okhttp/3.12.1' \
    --header 'CF-Client-Version: a-6.10-2158' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${TOKEN}" |
    python3 -m json.tool
}

# List bound devices
account_binding_devices() {
  [[ -z "$ID" && -z "$TOKEN" ]] && fetch_account_information

  curl --request GET "https://api.cloudflareclient.com/v0a2158/reg/${ID}/account/devices" \
    --silent \
    --location \
    --header 'User-Agent: okhttp/3.12.1' \
    --header 'CF-Client-Version: a-6.10-2158' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${TOKEN}" |
    python3 -m json.tool
}

# Change device name
change_device_name() {
  [[ -z "$ID" && -z "$TOKEN" ]] && fetch_account_information

  curl --request PATCH "https://api.cloudflareclient.com/v0a2158/reg/${ID}" \
    --silent \
    --location \
    --header 'User-Agent: okhttp/3.12.1' \
    --header 'CF-Client-Version: a-6.10-2158' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${TOKEN}" \
    --data '{"name":"'$DEVICE_NAME'"}' |
    python3 -m json.tool
}

# Change license
change_license() {
  [ "$#" = 3 ] && local ID="$1" && local TOKEN="$2" && local LICENSE="$3"
  [[ -z "$ID" && -z "$TOKEN" ]] && fetch_account_information

  curl --request PUT "https://api.cloudflareclient.com/v0a2158/reg/${ID}/account" \
    --silent \
    --location \
    --header 'User-Agent: okhttp/3.12.1' \
    --header 'CF-Client-Version: a-6.10-2158' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${TOKEN}" \
    --data '{"license": "'$LICENSE'"}' |
    python3 -m json.tool
}

# Unbind device
unbind_devide() {
  [[ -z "$ID" && -z "$TOKEN" ]] && fetch_account_information

  curl --request PATCH "https://api.cloudflareclient.com/v0a2158/reg/${ID}/account/reg/${ID}" \
    --silent \
    --location \
    --header 'User-Agent: okhttp/3.12.1' \
    --header 'CF-Client-Version: a-6.10-2158' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${TOKEN}" \
    --data '{"active":false}' |
    python3 -m json.tool
}

# Cancel account
cancle_account() {
  [ "$#" = 2 ] && local ID="$1" && local TOKEN="$2"
  [[ -z "$ID" && -z "$TOKEN" ]] && fetch_account_information

  local RESULT=$(curl --request DELETE "https://api.cloudflareclient.com/v0a2158/reg/${ID}" \
    --head \
    --silent \
    --location \
    --header 'User-Agent: okhttp/3.12.1' \
    --header 'CF-Client-Version: a-6.10-2158' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer ${TOKEN}" | awk '/HTTP/{print $(NF-1)}')

  grep -qw '204' <<<"$RESULT" && echo " Success. The account has been cancelled. " || echo " Failure. The account is not available. "
}

# Decode reserved
decode_reserved() {
  [[ -z "$ID" && -z "$TOKEN" ]] && fetch_account_information
  [ -z "$CLIENT_ID" ] && {
    fetch_client_id=$(device_information)
    CLIENT_ID=$(expr " $fetch_client_id" | awk -F'"' '/client_id/{print $4}')
  }
  if [ -x "$(type -p od)" ]; then
    RESERVED=$(echo "$CLIENT_ID" | base64 -d | od -An -tu1 | awk '{print "["$1", "$2", "$3"]"}')
  else
    RESERVED=$(echo "$CLIENT_ID" | base64 -d | xxd -p | fold -w2 | while read HEX; do printf '%d ' "0x${HEX}"; done | awk '{print "["$1", "$2", "$3"]"}')
  fi
  echo -e "client id: $CLIENT_ID\nreserved : $RESERVED"
}

# Get Team token
get_token() {
  until grep -sq 'HTTP/2 302' <<<"$DATA_1"; do
    ((ERROR_ORGANIZATION_TIME++))
    if [ "$ERROR_ORGANIZATION_TIME" = 1 ]; then
      [ -z "$ORGANIZATION" ] && read -rp "Organization: " ORGANIZATION
      [ -z "$EMAIL" ] && read -rp "Email: " EMAIL
    elif [[ "$ERROR_ORGANIZATION_TIME" > 5 ]]; then
      echo " Error: Please check your organization name! " && exit 1
    else
      read -rp "Please re-enter the organization: " ORGANIZATION
    fi
    DATA_1=$(curl -I -s "https://${ORGANIZATION}.cloudflareaccess.com/warp" | grep -E '^HTTP/2|^location|CF_AppSession=' | sed 's/\r//g')
  done

  KID=$(echo "$DATA_1" | sed -n '/^location/ s/.*?kid=//p')

  CF_APPSESSION=$(echo "$DATA_1" | awk -F '[=;]' '/CF_AppSession=/{print $2}')

  CF_SESSION=$(curl "https://${ORGANIZATION}.cloudflareaccess.com/cdn-cgi/access/login/${ORGANIZATION}.cloudflareaccess.com?kid=${KID}" \
    --head \
    --silent \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
    -H 'accept-language: zh-CN,zh;q=0.9' \
    -H 'cache-control: max-age=0' \
    -H "cookie: CF_AppSession=$CF_APPSESSION" \
    -H 'dnt: 1' \
    -H 'priority: u=0, i' \
    -H 'sec-ch-ua: "Not/A)Brand";v="8", "Chromium";v="126", "Google Chrome";v="126"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "Linux"' \
    -H 'sec-fetch-dest: document' \
    -H 'sec-fetch-mode: navigate' \
    -H 'sec-fetch-site: none' \
    -H 'sec-fetch-user: ?1' \
    -H 'upgrade-insecure-requests: 1' \
    -H 'user-agent: okhttp/3.12.1' |
    awk -F '[=;]' '/CF_Session=/{print $2}' | sed 's/\r//g')

  NONCE=$(curl "https://${ORGANIZATION}.cloudflareaccess.com/cdn-cgi/access/verify-code/${ORGANIZATION}.cloudflareaccess.com?kid=${KID}" \
    --include \
    --silent \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
    -H 'accept-language: zh-CN,zh;q=0.9' \
    -H 'cache-control: max-age=0' \
    -H 'content-type: application/x-www-form-urlencoded' \
    -H "cookie: CF_AppSession=$CF_APPSESSION; CF_Session=$CF_SESSION" \
    -H 'dnt: 1' \
    -H "origin: https://${ORGANIZATION}.cloudflareaccess.com" \
    -H 'priority: u=0, i' \
    -H "referer: https://${ORGANIZATION}.cloudflareaccess.com/cdn-cgi/access/login/${ORGANIZATION}.cloudflareaccess.com?kid=${KID}" \
    -H 'sec-ch-ua: "Not/A)Brand";v="8", "Chromium";v="126", "Google Chrome";v="126"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "Linux"' \
    -H 'sec-fetch-dest: document' \
    -H 'sec-fetch-mode: navigate' \
    -H 'sec-fetch-site: same-origin' \
    -H 'sec-fetch-user: ?1' \
    -H 'upgrade-insecure-requests: 1' \
    -H 'user-agent: okhttp/3.12.1' \
    --data-raw "email=${EMAIL}&client_id=&connector_id=&connector_type=&redirect_url=" |
    sed -n '/^location/ s/^location.*&nonce=//p' | sed 's/\r//g')

  until [ "$(grep -cs '^set-cookie:' <<<"$DATA_2")" = '2' ]; do
    ((ERROR_CODE_TIME++))
    if [ "$ERROR_CODE_TIME" = 1 ]; then
      read -rp "Enter the verification code and press [r] to resend the email: " CODE
    elif [[ "$ERROR_CODE_TIME" > 5 ]]; then
      echo " Failed too many times and the script exits. " && exit 1
    else
      read -rp "Please re-enter the verification code and press [r] to resend the email: " CODE
    fi
    if [[ "$CODE" =~ ^[0-9]{6}$ ]]; then
      DATA_2=$(curl "https://${ORGANIZATION}.cloudflareaccess.com/cdn-cgi/access/callback" \
        --include \
        --silent \
        -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
        -H 'accept-language: zh-CN,zh;q=0.9' \
        -H 'cache-control: max-age=0' \
        -H 'content-type: application/x-www-form-urlencoded' \
        -H "cookie: CF_AppSession=$CF_APPSESSION; CF_Session=$CF_SESSION" \
        -H 'dnt: 1' \
        -H "origin: https://${ORGANIZATION}.cloudflareaccess.com" \
        -H 'priority: u=0, i' \
        -H "referer: https://${ORGANIZATION}.cloudflareaccess.com/cdn-cgi/access/verify-code/${ORGANIZATION}.cloudflareaccess.com?kid=${KID}&nonce=${NONCE}" \
        -H 'sec-ch-ua: "Not/A)Brand";v="8", "Chromium";v="126", "Google Chrome";v="126"' \
        -H 'sec-ch-ua-mobile: ?0' \
        -H 'sec-ch-ua-platform: "Linux"' \
        -H 'sec-fetch-dest: document' \
        -H 'sec-fetch-mode: navigate' \
        -H 'sec-fetch-site: same-origin' \
        -H 'sec-fetch-user: ?1' \
        -H 'upgrade-insecure-requests: 1' \
        -H 'user-agent: okhttp/3.12.1' \
        --data-raw "code=${CODE}&nonce=${NONCE}" | grep -E '^location.*authorized|CF_Authorization=|CF_Device=' | sed 's/\r//g')
    elif [[ "$CODE" =~ ^[Rr] ]]; then
      unset CODE DATA_2
      curl "https://${ORGANIZATION}.cloudflareaccess.com/cdn-cgi/access/resend-code?nonce=${NONCE}" \
        --include \
        --silent \
        -H 'accept: */*' \
        -H 'accept-language: zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7' \
        -H 'cookie: CF_Session=nYTgDfwY1ppmkBmoJ' \
        -H 'dnt: 1' \
        -H 'priority: u=1, i' \
        -H "referer: https://${ORGANIZATION}.cloudflareaccess.com/cdn-cgi/access/verify-code/${ORGANIZATION}.cloudflareaccess.com?kid=${Kid}&nonce=${NONCE}" \
        -H 'sec-ch-ua: "Not/A)Brand";v="8", "Chromium";v="126", "Google Chrome";v="126"' \
        -H 'sec-ch-ua-mobile: ?0' \
        -H 'sec-ch-ua-platform: "Linux"' \
        -H 'sec-fetch-dest: empty' \
        -H 'sec-fetch-mode: cors' \
        -H 'sec-fetch-site: same-origin' \
        -H 'user-agent: okhttp/3.12.1' >/dev/null 2>&1
    fi
  done

  CF_AUTHORIZATION=$(echo "$DATA_2" | awk -F '[=;]' '/CF_Authorization=/{print $2}')
  CF_DEVICE=$(echo "$DATA_2" | awk -F '[=;]' '/CF_Device=/{print $2}')

  TEAM_TOKEN=$(curl -i -s "https://${ORGANIZATION}.cloudflareaccess.com/warp" \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
    -H 'accept-language: zh-CN,zh;q=0.9' \
    -H 'cache-control: no-cache' \
    -H "cookie: CF_AppSession=${CF_APPSESSION}; CF_Authorization=${CF_AUTHORIZATION}; CF_Device=${CF_DEVICE}" \
    -H 'dnt: 1' \
    -H 'pragma: no-cache' \
    -H 'priority: u=0, i' \
    -H "referer: https://${ORGANIZATION}.cloudflareaccess.com/cdn-cgi/access/verify-code/${ORGANIZATION}.cloudflareaccess.com?kid=${KID}" \
    -H 'sec-ch-ua: "Not/A)Brand";v="8", "Chromium";v="126", "Google Chrome";v="126"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "Linux"' \
    -H 'sec-fetch-dest: document' \
    -H 'sec-fetch-mode: navigate' \
    -H 'sec-fetch-site: same-origin' \
    -H 'sec-fetch-user: ?1' \
    -H 'upgrade-insecure-requests: 1' \
    -H 'user-agent: okhttp/3.12.1' |
    awk -F \' '/location.href/{print $2}' | grep -o "com\.cloudflare\.warp.*")

  if grep -q "^com\.cloudflare\.warp" <<<"$TEAM_TOKEN"; then
    grep -q 'is_output' <<<"$1" && echo "$TEAM_TOKEN" && exit 0
  else
    echo -e " Failed to get team token. \n" && exit 1
  fi
}

[[ "$#" -eq '0' ]] && help && exit

# MASQUE default parameters
CONFIG_FILE="config.json"
DEVICE_NAME=""
REGEN_KEY=false
ACTION=""

while [[ $# -ge 1 ]]; do
  case "${1,,}" in
  -f | --file)
    shift
    REGISTER_PATH="$1"
    shift
    ;;
  -r | --register)
    RUN=register_account
    shift
    ;;
  -d | --device)
    RUN=device_information
    shift
    ;;
  -a | --app)
    RUN=app_information
    shift
    ;;
  -b | --bind)
    RUN=account_binding_devices
    shift
    ;;
  -n | --name)
    shift
    DEVICE_NAME="$1"
    RUN=change_device_name
    shift
    ;;
  -l | --license)
    shift
    LICENSE="$1"
    RUN=change_license
    shift
    ;;
  -u | --unbind)
    RUN=unbind_devide
    shift
    ;;
  -c | --cancle)
    RUN=cancle_account
    shift
    ;;
  -i | --id)
    RUN=decode_reserved
    shift
    ;;
  -t | --token)
    shift
    TEAM_TOKEN=$(sed 's/.*?token=//' <<<"$1")
    shift
    ;;
  -e | --email)
    RUN=register_account
    shift
    EMAIL="$1"
    shift
    ;;
  -o | --organization)
    RUN=register_account
    shift
    ORGANIZATION="$1"
    shift
    ;;
  -m | --masque-register)
    RUN=masque_register_account
    ACTION="register"
    shift
    ;;
  -s | --masque-enroll)
    RUN=masque_enroll_account
    ACTION="enroll"
    shift
    ;;
  -g | --config)
    shift
    CONFIG_FILE="$1"
    shift
    ;;
  -p | --device-name)
    shift
    DEVICE_NAME="$1"
    shift
    ;;
  -k | --regen-key)
    REGEN_KEY=true
    shift
    ;;
  -h | --help)
    help
    exit
    ;;
  *)
    help
    exit
    ;;
  esac
done

# Parameter validation
if grep -q . <<<"$EMAIL" || grep -q . <<<"$ORGANIZATION"; then
  if grep -q . <<<"$REGISTER_PATH"; then
    RUN="register_account"
    get_token no_output
  else
    RUN="get_token is_output"
  fi
fi

# Execute based on parameters
$RUN

