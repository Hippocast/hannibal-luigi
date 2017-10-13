#!/usr/bin/env bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <container_tag>"
    exit 1
fi

DATE=$(date +"%m%d-%H%M")



gcloud beta compute --project "open-targets-eu-dev" instances create "hannibal-$1-$DATE" \
 --zone "europe-west1-d" \
 --machine-type "n1-standard-1" \
 --subnet "default" \
 --no-restart-on-failure \
 --maintenance-policy "TERMINATE" \
 --preemptible \
 --scopes default,storage-rw \
 --min-cpu-platform "Automatic" \
 --image-project "debian-cloud" \
 --image-family debian-9 \
 --boot-disk-size "250" \
 --boot-disk-type "pd-ssd" \
 --boot-disk-device-name "hannibal-$1-$DATE" \
 --metadata-from-file startup-script=hannibal-debian.sh \
 --metadata "container-tag=$1" \
 --labels app=hannibal
#  --machine-type "custom-40-266240" \


