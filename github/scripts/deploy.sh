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

# Migrates the database.
# Usage: migratedb folder network_name
#   - migratedb aircaptain_prod aircaptain-infra-local
migratedb() {
    local folder="$1"
    local network_name="$2"
    echo "Migrating the database, with the network name ${network_name}"

    # Run dbmate migrations by connecting to the database:
    #   - Attaching container to the network we got above
    #   - Using connection string from the secrets file (regular secrets.env, not secrets-compose.env)
    docker run --rm \
        --network "${network_name}" \
        -v "/tmp/${folder}/db/migrations:/db/migrations" \
        --env-file "/data/${folder}/secrets.env" \
        amacneil/dbmate:latest --wait up

    # Exit if database migration failed.
    if [ $? -ne 0 ]; then
        echo "DB Migration failed! Failing the script."
        exit 1
    fi
}

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
    compose_file="swarm-compose.yml" # We use a separate compose file for Swarm deployments.
fi

# Project/Stack name should always have a prefix, even for production.
# Otherwise GREP for prod containers will find other envs.
# Will be prod-app for prod, dev-app for dev.
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
echo "Container/Stack name: ${stack_name}"

# CD to the folder and move environment-specific .env file to .env file.
cd "/tmp/${folder}"
mv ".env.${DEPLOYMENT_ENVIRONMENT}" .env

# When deploying swarm service, we always redeploy the whole stack (even when only api has changed).
# So we need to get the other (not changed) module's SHA tags from currently running stack.
# So that the stack redeployment will use them.
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

# Update .env file with our specific version tags.
sed -i "s/API_TAG=/API_TAG=$API_SHA_TAG/g" .env
sed -i "s/WEB_TAG=/WEB_TAG=$WEB_SHA_TAG/g" .env

if [[ "${DEPLOYMENT_IS_PRODUCTION}" == "true" ]]; then
    # For production we remove any exposed ports (forwarding) for security.
    sed -i '/ports:/{N;d}' "${compose_file}"
else
    # Uncomment connection to helpful infrastructure for DEV envs.
    sed -i "s/#- admin/- admin/g" "${compose_file}"
    sed -i "s/#- internet/- internet/g" "${compose_file}"
fi

# When regular Compose (non-Swarm) deployment is in effect - this part of script is being used.
# For Swarm deployments scroll down to the bottom half.
if [[ "${IS_SWARM}" != "true" ]]; then
    # Deploying regular compose.
    echo "Deploying using regular Docker Compose (NON Swarm mode)"
    deploy_services=$(docker compose config --services) # Get services list from docker-compose file.
    if [ -z "${API_SHA_TAG}" ]; then
        # If API did not change - remove it from the list of services for deployment.
        echo "API will not be deployed."
        deploy_services=$(echo "${deploy_services}" | tr ' ' '\n' | grep -v '^api$' | tr '\n' ' ')
    fi
    if [ -z "${WEB_SHA_TAG}" ]; then
        # If Web did not change - remove it from the list of services for deployment.
        echo "WEB will not be deployed."
        deploy_services=$(echo "${deploy_services}" | tr ' ' '\n' | grep -v '^web$' | tr '\n' ' ')
    fi
    docker compose pull

    echo "Bringing up the database"
    docker compose up -d postgres # Makes sure database is deployed (like during first deployment).
    if [ "$DB_CHANGED" == "true" ]; then
        # Migrate the database when it has changed.
        echo "Database has changed, running migrations."
        # Get 'local' network name configured for this service.
        NETWORK_NAME=$(docker compose config --format json | jq -r '.networks["local"].name')
        # Stop the API before migrating the database.
        docker compose stop api
        # Run dbmate migrations by connecting to the database:
        #   - Attaching container to the network we got above
        #   - Using connection string from the secrets file (regular secrets.env, not secrets-compose.env)
        docker run --rm \
            --network "${NETWORK_NAME}" \
            -v "/tmp/${folder}/db/migrations:/db/migrations" \
            --env-file "/data/${folder}/secrets.env" \
            amacneil/dbmate:latest --wait up

        migrationSucceeded="$?"

        # Restart the old API container.
        docker compose start api

        # If migration failed - exit the script.
        if [ $migrationSucceeded -ne 0 ]; then
            echo "Migration failed, exiting the script"
            exit 1
        fi
    fi

    # Deploying any services that need deployment.
    # Also starting Doneman container that monitors necessary overlay networks
    # and restarts/reconnects containers if needed.
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
        # If database is not running - most likely it's the first deployment. Deploying the stack.
        echo "Database is not running, probably first time deployment. Deploying the stack and migrating DB."
        docker stack deploy "${stack_name}" --compose-file swarm-compose.yml --detach=false

        # Migrate the database (more info above, in the non-swarm comments).
        network_name=$(docker compose -f swarm-compose.yml config --format json | jq -r '.networks["local"].name')

        # Migrate the DB.
        migratedb "${folder}" "${network_name}"

        exit 0;
    fi

    if [ "$DB_CHANGED" == "true" ]; then
        # If database has changed - migrate the database first.
        echo 'Database is running, and DB scripts have changed. Migrating the database'
        network_name=$(docker compose -f swarm-compose.yml config --format json | jq -r '.networks["local"].name')

        # Migrate the DB.
        migratedb "${folder}" "${network_name}"
    fi

    # Deploy the stack.
    echo "Deploying the stack"
    docker stack deploy "${stack_name}" --compose-file swarm-compose.yml --detach=false

    # We don't need to keep the files for Swarm deployments.
    # But keep them for regular (in case we want to stop the stack).
    echo "Cleaning up the folder"
    rm -rf "/tmp/${folder}"
fi

