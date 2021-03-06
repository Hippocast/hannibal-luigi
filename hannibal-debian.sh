#!/bin/bash

apt-get update && DEBIAN_FRONTEND=noninteractive \
    apt-get \
    -o Dpkg::Options::="--force-confnew" \
    --force-yes \
    -fuy \
    dist-upgrade && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get \
    -o Dpkg::Options::="--force-confnew" \
    --force-yes \
    -fuy \
    -t stretch-backports install net-tools \
                                    wget less tmux htop jq httpie silversearcher-ag\
                                    uuid-runtime \
                                    python-pip \
                                    python-dev \
                                    libyaml-dev \
                                    apt-transport-https \
                                    ca-certificates \
                                    curl \
                                    gnupg2 \
                                    software-properties-common

curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo apt-key add -

add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
   $(lsb_release -cs) \
   stable"

mkdir /etc/docker
cat <<EOF >> /etc/docker/daemon.json
{
  "log-driver": "syslog"
}
EOF

apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce
systemctl enable docker

## install stackdriver logging agent 
# as explained in https://cloud.google.com/logging/docs/agent/installation
curl -sSO https://dl.google.com/cloudagents/install-logging-agent.sh
bash install-logging-agent.sh


############## shell env #####################


## download my dotfiles for tmux and shell niceties
wget -O ~/.tmux.conf https://git.io/v9FuI
wget -O ~/.mybashrc https://git.io/vbJQT
cat ~/.mybashrc >> ~/.bashrc

## add variables needed for ES and luigi
cat <<EOF >> ~/.bashrc

### Variables I need for ES and Luigi ###

## Compute half memtotal gigs 
# cap ES heap at 26 to safely remain under zero-base compressed oops limit
# see: https://www.elastic.co/guide/en/elasticsearch/reference/current/heap-size.html
export ES_MEM=\$(awk '/MemTotal/ {half=\$2/1024/2; if (half > 52*1024) printf 52*1024; else printf "%d", half}' /proc/meminfo)
export ES_HEAP=\$((\$ES_MEM/2))

## Cap CPUs for ES to 8
export ES_CPU=\$(nproc | awk '{if (\$NF/2 < 8) print \$NF/2; else print 8}')

## read metadata
export INSTANCE_NAME=\$(http --ignore-stdin --check-status 'http://metadata.google.internal/computeMetadata/v1/instance/name'  "Metadata-Flavor:Google" -p b --pretty none)
export CONTAINER_TAG=\$(http --ignore-stdin --check-status 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/container-tag'  "Metadata-Flavor:Google" -p b --pretty none)
export ESURL=\$(http --ignore-stdin --check-status 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/es-url'  "Metadata-Flavor:Google" -p b --pretty none)
export PUBESURL=\$(http --ignore-stdin --check-status 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/pub-es-url'  "Metadata-Flavor:Google" -p b --pretty none)
export SLACK_TOKEN=\$(http --ignore-stdin --check-status 'http://metadata.google.internal/computeMetadata/v1/project/attributes/slack-token'  "Metadata-Flavor:Google" -p b --pretty none)
export KEEPUP=\$(http --ignore-stdin --check-status 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/keepup'  "Metadata-Flavor:Google" -p b --pretty none)
export LUIGI_CONFIG_PATH=/hannibal/src/luigi.cfg
EOF

echo "export variables"
# NOTE I am also sourcing bashrc variables here, because .bashrc is not sourced during startup-script
source /root/.bashrc


####################### hannibal ##########################
mkdir /hannibal
mkdir /hannibal/logs
mkdir /hannibal/status

# clone the hannibal repo with the task definition and install python packages needed
pip install --upgrade pip 
git clone https://github.com/opentargets/hannibal.git /hannibal/src
pip install -r /hannibal/src/requirements.txt

envsubst < /hannibal/src/luigi.cfg.template > /hannibal/src/luigi.cfg

chown -R root:google-sudoers /hannibal

####################### internal elasticsearch? ##############

if [ "$ESURL" = "http://elasticsearch:9200" ]; then

    echo "map elasticsearch DNS to localhost"
    echo "127.0.0.1 elasticsearch" >> /etc/hosts

    echo "spin my own elasticsearch using docker... "

    docker network create esnet
    gcloud docker -- pull gcr.io/open-targets-eu-dev/github-opentargets-docker-elasticsearch-singlenode:5.6
    
    echo Spin elasticsearch 
    # TODO make sure that when the process gets restarted with different memory and CPU requirements, this command update. Perhaps needs to be in a systemd service?
    docker run -d -p 9200:9200 -p 9300:9300 \
        --name elasticsearch \
        --network=esnet \
        -v esdatavol:/usr/share/elasticsearch/data \
        -e "discovery.type=single-node" \
        -e "xpack.security.enabled=false" \
        -e "cluster.name=hannibal" \
        -e "bootstrap.memory_lock=true" \
        -e "ES_JAVA_OPTS=-Xms${ES_HEAP}m -Xmx${ES_HEAP}m" \
        -e "reindex.remote.whitelist=10.*.*.*:*, _local_:*" \
        --log-driver=gcplogs \
        --log-opt gcp-log-cmd=true \
        --cpus=${ES_CPU} \
        -m ${ES_MEM}M \
        --ulimit memlock=-1:-1 \
        --restart=always \
        gcr.io/open-targets-eu-dev/github-opentargets-docker-elasticsearch-singlenode:5.6


    # # NOTE: we don't have to explicity set the ulimits over files, since
    # the debian docker daemon sets acceptable ones 
    # Tested with `docker run --rm centos:7 /bin/bash -c 'ulimit -Hn && ulimit -Sn && ulimit -Hu && ulimit -Su'`

    ## Change index settings (after ES is ready)
    # # wait enough to get elasticsearch running and ready
    until $(curl --output /dev/null --silent --fail http://127.0.0.1:9200/_cat/indices); do
        printf '.'
        sleep 5
    done

    echo configure gcs snapshot plugin repository
    cat <<EOF > /root/snapshot_gcs.json
{
"type": "gcs",
"settings": {
    "bucket": "ot-snapshots",
    "base_path": "${INSTANCE_NAME}",
    "max_restore_bytes_per_sec": "1000mb",
    "max_snapshot_bytes_per_sec": "1000mb"
}
}
EOF

    http --check-status -p b --pretty none PUT :9200/_snapshot/${INSTANCE_NAME} < /root/snapshot_gcs.json

    echo start kibana in the background
    docker run -p 5601:5601 --network esnet -d docker.elastic.co/kibana/kibana:5.6.3

    echo '{"index":{"number_of_replicas":0}}' | http PUT :9200/_settings

fi


gcloud docker -- pull eu.gcr.io/open-targets/mrtarget:${CONTAINER_TAG}

## central scheduler for the visualization
luigid --background

# make sure luigi runs at reboot
cat <<EOF >/hannibal/launch_luigi.sh
#!/usr/bin/env bash
source /root/.bashrc
PYTHONPATH="/hannibal/src" luigi --module pipeline-dockertask ReleaseAndSelfDestruct --workers 5
EOF

chmod u+x /hannibal/launch_luigi.sh

cat <<EOF >/etc/systemd/system/luigi.service
[Unit]
AssertPathExists=/hannibal/src
Description=hannibal and luigi

[Service]
WorkingDirectory=/hannibal
ExecStart=/hannibal/launch_luigi.sh
Restart=on-abnormal
RestartSec=30
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=default.target

EOF

systemctl enable --now luigi

