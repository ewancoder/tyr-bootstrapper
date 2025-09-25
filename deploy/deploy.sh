#!/usr/bin/env bash
# Usage: deploy.sh
# This is a deployment script for deployment of typical service containing:
#   - .NET API
#   - Database (DbMate)
#   - Web app (Angular)
# Data should be in the /data/${PROJECT_NAME}_${DEPLOYMENT_ENVIRONMENT},
# scripts are placed to /tmp/${PROJECT_NAME}_${DEPLOYMENT_ENVIRONMENT}.
# When deploying in non-swarm mode this script assumes specific container names (api, doneman, etc) in docker-compose file.
# Environment variables:
#   DB_CHANGED
#   API_SHA_TAG
#   WEB_SHA_TAG
#   PROJECT_NAME - lowercase project name key, e.g. aircaptain
#   DEPLOYMENT_ENVIRONMENT (prod for production, dev for development)
#   DEPLOYMENT_IS_PRODUCTION (indicates that this environment should have security measures in place)
#   IS_SWARM - indicates whether it's a Swarm deployment.

set -euo pipefail
echo "deploy.sh v1"

API_SHA_TAG="${API_SHA_TAG:-}"
WEB_SHA_TAG="${WEB_SHA_TAG:-}"

if [ -z "${DB_CHANGED:-}" ] \
    || [ -z "${PROJECT_NAME:-}" ] \
    || [ -z "${DEPLOYMENT_ENVIRONMENT:-}" ] \
    || [ -z "${DEPLOYMENT_IS_PRODUCTION:-}" ] \
    || [ -z "${IS_SWARM:-}" ]; then
    echo "Mandatory environment variables are not set."
    exit 1
fi

# This folder is used both for deployment files (/tmp/folder) and for data placement (/data/folder).
folder="${PROJECT_NAME}_${DEPLOYMENT_ENVIRONMENT}"
compose_file="docker-compose.yml"
if [[ "${IS_SWARM}" == "true" ]]; then
    compose_file="swarm-compose.yml"
fi

# Project/Stack name should always have a prefix, even for production.
# Otherwise GREP for prod containers will find other envs.
project_container_name="${DEPLOYMENT_ENVIRONMENT}-${PROJECT_NAME}"
stack_name="${project_container_name}"

echo "DB_CHANGED: ${DB_CHANGED}"
echo "API_SHA_TAG: ${API_SHA_TAG}"
echo "WEB_SHA_TAG: ${WEB_SHA_TAG}"
echo "PROJECT_NAME: ${PROJECT_NAME}"
echo "DEPLOYMENT_ENVIRONMENT: ${DEPLOYMENT_ENVIRONMENT}"
echo "DEPLOYMENT_IS_PRODUCTION: ${DEPLOYMENT_IS_PRODUCTION}"
echo "IS_SWARM: ${IS_SWARM}"
echo "Folder: ${folder}"

cd "/tmp/${folder}"
mv ".env.${DEPLOYMENT_ENVIRONMENT}" .env

# TODO: Do the same for non-swarm deployment, get the currently running SHAs for redeployment.
if [[ "${IS_SWARM}" == "true" ]]; then
    if [ -z "${API_SHA_TAG}" ]; then
        API_SHA_TAG=$(docker service inspect "${project_container_name}_api" --pretty | grep image= | awk -F: '{print $2}')
        echo "API did not change. Using $API_SHA_TAG tag."
    fi
    if [ -z "${WEB_SHA_TAG}" ]; then
        WEB_SHA_TAG=$(docker service inspect "${project_container_name}_web" --pretty | grep image= | awk -F: '{print $2}')
        echo "WEB did not change. Using $WEB_SHA_TAG tag."
    fi
fi

sed -i "s/API_TAG=/API_TAG=$API_SHA_TAG/g" .env
sed -i "s/WEB_TAG=/WEB_TAG=$WEB_SHA_TAG/g" .env

if [[ "${DEPLOYMENT_IS_PRODUCTION}" == "true" ]]; then
    sed -i '/ports:/{N;d}' "${compose_file}" # Delete ports forwarding for production envs.
else
    # Uncomment connection to helpful infrastructure for DEV envs.
    sed -i "s/#- admin/- admin/g" "${compose_file}"
    sed -i "s/#- internet/- internet/g" "${compose_file}"
fi

if [[ "${IS_SWARM}" != "true" ]]; then
    # Deploying regular compose.
    echo "Deploying using regular Docker Compose (NON Swarm mode)"
    deploy_services=$(docker compose config --services)
    if [ -z "${API_SHA_TAG}" ]; then
        echo "API will not be deployed."
        deploy_services=$(echo "${deploy_services}" | tr ' ' '\n' | grep -v '^api$' | tr '\n' ' ')
    fi
    if [ -z "${WEB_SHA_TAG}" ]; then
        echo "WEB will not be deployed."
        deploy_services=$(echo "${deploy_services}" | tr ' ' '\n' | grep -v '^web$' | tr '\n' ' ')
    fi
    docker compose pull

    echo "Bringing up the database"
    docker compose up -d postgres
    if [ "$DB_CHANGED" == "true" ]; then
        echo "Database has changed, running migrations."
        NETWORK_NAME=$(docker compose config --format json | jq -r '.networks["local"].name')
        docker compose stop api
        docker run --rm \
            --network "${NETWORK_NAME}" \
            -v "/tmp/${folder}/db/migrations:/db/migrations" \
            --env-file "/data/${folder}/secrets.env" \
            amacneil/dbmate:latest --wait up

        if [ $? -ne 0 ]; then
            echo "Migration failed, restarting old api containers and exiting"
            docker compose start api
            exit 1
        fi
    fi

    if [ -z "${API_SHA_TAG}" ]; then
        echo "API is not being deployed, restarting old container."
        docker compose start api
    fi
    echo "Deploying the following services: ${deploy_services}"
    docker compose up -d ${deploy_services} # Cannot quote this, so different services are treated as different entries.
    docker compose cp .env doneman:/.env
    docker compose cp docker-compose.yml doneman:/docker-compose.yml
    docker compose restart doneman
else
    # This is only needed for Swarm deployments, regular Compose reads env files by itself.
    # We should never encase this in "" or it won't expand correctly.
    export $(cat .env | xargs)

    echo "Redeploying the stack"
    if ! docker ps | grep -q "${project_container_name}_postgres"; then
        echo "Database is not running, probably first time deployment. Deploying the stack and migrating DB."
        docker stack deploy "${stack_name}" --compose-file swarm-compose.yml --detach=false

        NETWORK_NAME=$(docker compose -f swarm-compose.yml config --format json | jq -r '.networks["local"].name')
        docker run --rm \
            --network "${NETWORK_NAME}" \
            -v "/tmp/${folder}/db/migrations:/db/migrations" \
            --env-file "/data/${folder}/secrets.env" \
            amacneil/dbmate:latest --wait up

        if [ $? -ne 0 ]; then
            echo "DB Migration failed! Failing the script."
            exit 1
        fi

        exit 0;
    fi

    if [ "$DB_CHANGED" == "true" ]; then
        echo 'Database is running, and DB scripts have changed. Migrating the database'
        NETWORK_NAME=$(docker compose -f swarm-compose.yml config --format json | jq -r '.networks["local"].name')

        docker run --rm \
            --network "${NETWORK_NAME}" \
            -v "/tmp/${folder}/db/migrations:/db/migrations" \
            --env-file "/data/${folder}/secrets.env" \
            amacneil/dbmate:latest --wait up

        if [ $? -ne 0 ]; then
            echo "DB Migration failed! Failing the script."
            exit 1
        fi
    fi

    echo "Deploying the stack"
    docker stack deploy "${stack_name}" --compose-file swarm-compose.yml --detach=false

    # We don't need to keep the files for Swarm deployments.
    # But keep them for regular (in case we want to stop the stack).
    echo "Cleaning up the folder"
    rm -rf "/tmp/${folder}"
fi
