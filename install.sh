#!/bin/bash -e

WORK_DIR=/opt/plugNmeet

## https://raw.githubusercontent.com/mynaparrot/plugNmeet-install/main/install-files
CONFIG_DOWNLOAD_URL="https://raw.githubusercontent.com/mynaparrot/plugNmeet-install/main/install-files"

## https://github.com/mynaparrot/plugNmeet-client/releases/latest/download/client.zip
CLIENT_DOWNLOAD_URL="https://github.com/mynaparrot/plugNmeet-client/releases/latest/download/client.zip"
RECORDER_DOWNLOAD_URL="https://github.com/mynaparrot/plugNmeet-recorder/releases/latest/download/recorder.zip"

## https://raw.githubusercontent.com/mynaparrot/plugNmeet-server/main/sql_dump/install.sql
SQL_DUMP_DOWNLOAD_URL="https://raw.githubusercontent.com/mynaparrot/plugNmeet-server/main/sql_dump/install.sql"

main() {
  can_run

  PLUG_N_MEET_SERVER_DOMAIN=
  while [[ $PLUG_N_MEET_SERVER_DOMAIN == "" ]]; do
    echo -n "Please enter plugNmeet server domain (exmple: plugnmeet.example.com): "
    read -r PLUG_N_MEET_SERVER_DOMAIN
  done

  LIVEKIT_SERVER_DOMAIN=
  while [[ $LIVEKIT_SERVER_DOMAIN == "" ]]; do
    echo -n "Please enter livekit server domain (exmple: livekit.example.com): "
    read -r LIVEKIT_SERVER_DOMAIN
  done

  TURN_SERVER_DOMAIN=
  while [[ $TURN_SERVER_DOMAIN == "" ]]; do
    echo -n "Please enter turn server domain (exmple: turn.example.com): "
    read -r TURN_SERVER_DOMAIN
  done

  EMAIL_ADDRESS=
  while [[ $EMAIL_ADDRESS == "" ]]; do
    echo -n "Please enter valid email address: "
    read -r EMAIL_ADDRESS
  done

  echo -n "Do you want to install recorder? y/n: "
  read -r RECORDER_INSTALL
  echo -n "Do you want to configure firewall(ufw)? y/n: "
  read -r CONFIGURE_UFW

  mkdir -p ${WORK_DIR}
  cd ${WORK_DIR}

  if ! which docker-compose >/dev/null; then
    install_docker
  fi

  install_haproxy
  prepare_server
  install_client
  prepare_etherpad

  if [ "$RECORDER_INSTALL" == "y" ]; then
    install_recorder
  fi

  if [ "$CONFIGURE_UFW" == "y" ]; then
    enable_ufw
  fi

  systemctl start plugnmeet
  printf "\nFinalizing setup..\n"
  # before going next step need to wait little bit time
  # to finish plugnmeet fully start
  # we'll check etherpad because it take most of the time
  while ! nc -z localhost 9001; do
    journalctl -u plugnmeet --no-pager -n 1
    sleep 3 # wait before check again
  done

  ## need restart if mariadb took too much time to import
  systemctl restart plugnmeet

  if [ "$RECORDER_INSTALL" == "y" ]; then
    # need redis server to up before start recorder service
    echo ".............."
    sleep 5
    systemctl start plugnmeet-recorder
  fi

  clear
  printf "Installation completed!\n\n"
  printf "plugNmeet server URL: https://${PLUG_N_MEET_SERVER_DOMAIN}\n"
  printf "plugNmeet API KEY: ${PLUG_N_MEET_API_KEY}\n"
  printf "plugNmeet API SECRET: ${PLUG_N_MEET_SECRET}\n"
  printf "livekit server URL: https://${LIVEKIT_SERVER_DOMAIN}\n"

  printf "\n\nTo manage server: \n"
  printf "systemctl stop plugnmeet or systemctl restart plugnmeet\n"

  if [ "$RECORDER_INSTALL" == "y" ]; then
    printf "\n\nTo manage recorder: \n"
    printf "systemctl stop plugnmeet-recorder or systemctl restart plugnmeet-recorder \n\n"
  fi

  printf "To test frontend: \n"
  printf "https://${PLUG_N_MEET_SERVER_DOMAIN}/login.html\n\n"

  printf "\nFor further performance tuning follow: \n"
  printf "https://docs.livekit.io/deploy/test-monitor#kernel-parameters\n\n"
}

random_key() {
  tr -dc A-Za-z0-9 </dev/urandom | dd bs=$1 count=1 2>/dev/null
}

install_docker() {
  apt -y install ca-certificates curl gnupg lsb-release

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt update
  apt -y install docker-ce docker-ce-cli containerd.io docker-compose
}

prepare_server() {
  wget ${CONFIG_DOWNLOAD_URL}/config.yaml -O config.yaml
  wget ${CONFIG_DOWNLOAD_URL}/livekit.yaml -O livekit.yaml
  wget ${CONFIG_DOWNLOAD_URL}/docker-compose.yaml -O docker-compose.yaml

  mkdir -p sql_dump
  mkdir -p redis-data
  chmod 777 redis-data
  wget ${SQL_DUMP_DOWNLOAD_URL} -O sql_dump/install.sql

  ## change livekit api & turn
  LIVEKIT_API_KEY=API$(random_key 11)
  LIVEKIT_SECRET=$(random_key 36)

  PLUG_N_MEET_API_KEY=API$(random_key 11)
  PLUG_N_MEET_SECRET=$(random_key 36)

  DB_ROOT_PASSWORD=$(random_key 20)
  sed -i "s/DB_ROOT_PASSWORD/$DB_ROOT_PASSWORD/g" docker-compose.yaml

  sed -i "s/LIVEKIT_API_KEY/$LIVEKIT_API_KEY/g" livekit.yaml
  sed -i "s/LIVEKIT_SECRET/$LIVEKIT_SECRET/g" livekit.yaml
  sed -i "s/TURN_SERVER_DOMAIN/$TURN_SERVER_DOMAIN/g" livekit.yaml

  sed -i "s/LIVEKIT_API_KEY/$LIVEKIT_API_KEY/g" config.yaml
  sed -i "s/LIVEKIT_SECRET/$LIVEKIT_SECRET/g" config.yaml
  sed -i "s/PLUG_N_MEET_API_KEY/$PLUG_N_MEET_API_KEY/g" config.yaml
  sed -i "s/PLUG_N_MEET_SECRET/$PLUG_N_MEET_SECRET/g" config.yaml
  sed -i "s/DB_ROOT_PASSWORD/$DB_ROOT_PASSWORD/g" config.yaml

  wget ${CONFIG_DOWNLOAD_URL}/plugnmeet.service -O /etc/systemd/system/plugnmeet.service
  systemctl daemon-reload
  systemctl enable plugnmeet
}

install_client() {
  wget $CLIENT_DOWNLOAD_URL -O client.zip
  unzip client.zip
  cp client/dist/assets/config_sample.js client/dist/assets/config.js

  sed -i "s/window.PLUG_N_MEET_SERVER_URL.*/window.PLUG_N_MEET_SERVER_URL = 'https:\/\/$PLUG_N_MEET_SERVER_DOMAIN'\;/g" \
    client/dist/assets/config.js
  sed -i "s/window.LIVEKIT_SERVER_URL.*/window.LIVEKIT_SERVER_URL = 'https:\/\/$LIVEKIT_SERVER_DOMAIN'\;/g" \
    client/dist/assets/config.js

  rm client.zip
}

prepare_etherpad() {
  mkdir -p etherpad
  wget ${CONFIG_DOWNLOAD_URL}/settings.json -O etherpad/settings.json
  wget ${CONFIG_DOWNLOAD_URL}/APIKEY.txt -O etherpad/APIKEY.txt
  
  ETHERPAD_API=$(random_key 80)
  
  sed -i "s/ETHERPAD_API/$ETHERPAD_API/g" etherpad/APIKEY.txt
  sed -i "s/ETHERPAD_API/$ETHERPAD_API/g" config.yaml
  sed -i "s/PLUG_N_MEET_SERVER_DOMAIN/https:\/\/$PLUG_N_MEET_SERVER_DOMAIN/g" config.yaml
}

prepare_recorder() {
  ## prepare chrome
  curl -sS -o - https://dl-ssl.google.com/linux/linux_signing_key.pub | apt-key add
  echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >/etc/apt/sources.list.d/google-chrome.list

  ## prepare nodejs
  curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -

  ## install require software
  apt -y update && apt -y install nodejs xvfb google-chrome-stable ffmpeg
}

install_recorder() {
  wget $CONFIG_DOWNLOAD_URL/plugnmeet-recorder.service -O /etc/systemd/system/plugnmeet-recorder.service
  wget $CONFIG_DOWNLOAD_URL/plugnmeet-recorder@main.service -O /etc/systemd/system/plugnmeet-recorder@main.service
  wget $CONFIG_DOWNLOAD_URL/plugnmeet-recorder@websocket.service -O /etc/systemd/system/plugnmeet-recorder@websocket.service
  systemctl daemon-reload
  systemctl enable plugnmeet-recorder
  systemctl enable plugnmeet-recorder@main
  systemctl enable plugnmeet-recorder@websocket

  wget $RECORDER_DOWNLOAD_URL -O recorder.zip
  unzip recorder.zip
  cp recorder/config_sample.yaml recorder/config.yaml

  WEBSOCKET_AUTH_TOKEN=$(random_key 10)
  sed -i "s/join_host.*/join_host: \"https:\/\/$PLUG_N_MEET_SERVER_DOMAIN\/\?access_token=\"/g" recorder/config.yaml
  sed -i "s/WEBSOCKET_AUTH_TOKEN/$WEBSOCKET_AUTH_TOKEN/g" recorder/config.yaml

  prepare_recorder

  npm install -C recorder
  rm recorder.zip
}

install_haproxy() {
  add-apt-repository ppa:vbernat/haproxy-2.4 -y
  apt -y update && apt install -y haproxy
  service haproxy stop

  cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg_bk
  mkdir -p /etc/haproxy/ssl

  configure_lets_encrypt

  ln -s /etc/letsencrypt/live/${PLUG_N_MEET_SERVER_DOMAIN}/fullchain.pem /etc/haproxy/ssl/${PLUG_N_MEET_SERVER_DOMAIN}.pem
  ln -s /etc/letsencrypt/live/${PLUG_N_MEET_SERVER_DOMAIN}/privkey.pem /etc/haproxy/ssl/${PLUG_N_MEET_SERVER_DOMAIN}.pem.key

  wget ${CONFIG_DOWNLOAD_URL}/haproxy_main.cfg -O /etc/haproxy/haproxy.cfg

  sed -i "s/PLUG_N_MEET_SERVER_DOMAIN/$PLUG_N_MEET_SERVER_DOMAIN/g" /etc/haproxy/haproxy.cfg
  sed -i "s/LIVEKIT_SERVER_DOMAIN/$LIVEKIT_SERVER_DOMAIN/g" /etc/haproxy/haproxy.cfg
  sed -i "s/TURN_SERVER_DOMAIN/$TURN_SERVER_DOMAIN/g" /etc/haproxy/haproxy.cfg
  ## 8.8.8.8 is using only to get default route
  SERVER_IP=$(ip route get 8.8.8.8 | awk -F "src " 'NR==1{split($2,a," ");print a[1]}')
  sed -i "s/SERVER_IP/$SERVER_IP/g" /etc/haproxy/haproxy.cfg

  wget ${CONFIG_DOWNLOAD_URL}/001-restart-haproxy -O /etc/letsencrypt/renewal-hooks/post/001-restart-haproxy
  chmod +x /etc/letsencrypt/renewal-hooks/post/001-restart-haproxy

  service haproxy start
}

configure_lets_encrypt() {
  wget ${CONFIG_DOWNLOAD_URL}/haproxy_lets_encrypt.cfg -O /etc/haproxy/haproxy.cfg
  service haproxy start

  if ! which snap >/dev/null; then
    apt install -y snapd
  fi

  snap install core
  snap refresh core
  snap install --classic certbot
  ln -s /snap/bin/certbot /usr/bin/certbot

  if ! certbot certonly --standalone -d $PLUG_N_MEET_SERVER_DOMAIN -d $LIVEKIT_SERVER_DOMAIN -d $TURN_SERVER_DOMAIN \
    --non-interactive --agree-tos --email $EMAIL_ADDRESS \
    --http-01-port=9080; then
    display_error "Let's Encrypt SSL request did not succeed - exiting"
  fi

  service haproxy stop
  rm /etc/haproxy/haproxy.cfg
}

can_run() {
  if [ $EUID != 0 ]; then display_error "You must run this script as root."; fi

  OS=$(lsb_release -si)
  if [ "$OS" != "Ubuntu" ]; then display_error "This script will require Ubuntu server."; fi

  apt update && apt install -y --no-install-recommends software-properties-common unzip net-tools netcat git
  clear
}

display_error() {
  echo "$1" >&2
  exit 1
}

enable_ufw() {
  if ! which ufw >/dev/null; then
    apt install -y ufw
  fi

  ufw allow ${SSH_CLIENT##* }/tcp
  ufw allow 22/tcp # for safety
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 7881/tcp
  ufw allow 443/udp
  ufw allow 50000:60000/udp

  ufw --force enable
}

main "$@" || exit 1
