#!/bin/ash
#set -xv

DSPACE_ADMIN_USERNAME=dspace-admin@oapass.org

# insure the database is up and simple query can be executed
function verify_db() {
    perform_query "SELECT 1" 2>&1 /dev/null
}

# performs the supplied query against the DSpace database
function perform_query() {
    psql -c "$1" -h ${DSPACE_DB_HOST} -p ${POSTGRES_DB_PORT} -w ${DSPACE_DB_NAME} ${DSPACE_DB_USER}
}

# blocks until the database is available, or returns 1 to indicate failure
function wait_for_db() {
    local RETRY_S=$1
    local LIMIT_S=$2
    local START_S=`date +%s`

    while [ $(expr `date +%s` - ${START_S}) -lt ${LIMIT_S} ] ;
    do
        (>&2 echo ">>> Waiting for database ...")
        verify_db
        if [ $? == 0 ] ;
        then
            (>&2 echo ">>> Database is up!")
            return 0;
        fi

        sleep ${RETRY_S}
    done

    (>&2 echo ">>> Database is not available!")
    exit 1
}

# tests to see if an admin user exists.  also happens to test whether or not the database tables have been created.
function admin_user_exists() {
    local ADMIN_COUNT=`perform_query "SELECT count(*) as admin_count FROM (SELECT eperson_id FROM epersongroup2eperson WHERE eperson_group_id IN (SELECT uuid FROM epersongroup WHERE name = 'Administrator')) admins, eperson WHERE admins.eperson_id = eperson.uuid" \
    | sed -n 3p | sed -e 's: ::g'`

    if [ $? == 0 -a ${ADMIN_COUNT:-0} -gt 0 ] ;
    then
        return 0
    fi
    return 1
}

# executes the command to create an admin user
function create_admin_user() {
    (>&2 echo ">>> Creating DSpace administrative user and DSpace database tables ...")
    ${DSPACE_INSTALL_DIR}/bin/dspace create-administrator -e ${DSPACE_ADMIN_USERNAME} -f DSpace -l Administrator -p foobar -c EN_US 2>&1 >/dev/null
}

# updates the runtime configuration of dspace based on docker environment vars
function perform_runtime_config() {
    (>&2 echo ">>> Configuring DSpace using the following environment:")
    (>&2 env)
    # Edit runtime configuration, configure per environment
    cd ${DSPACE_INSTALL_DIR}/config

    cp local.cfg.EXAMPLE local.cfg

    sed -e "s:^dspace.hostname = .*:dspace.hostname = ${DSPACE_HOST}:"  -i local.cfg
    sed -e "s:^dspace.baseUrl = .*:dspace.baseUrl = http\://${DSPACE_HOST}\:${DSPACE_PORT}:"  -i local.cfg
    sed -e "s:^db.url = .*:db.url = jdbc\:postgresql\://${DSPACE_DB_HOST}\:${POSTGRES_DB_PORT}/${DSPACE_DB_NAME}:"  -i local.cfg
    sed -e "s:^db.username = .*:db.username = ${DSPACE_DB_USER}:"  -i local.cfg
    sed -e "s:^db.password = .*:db.password = ${DSPACE_DB_PASS}:"  -i local.cfg
    sed -e "s:^loglevel.dspace=.*:loglevel.dspace=DEBUG:" -i log4j.properties

    # enable mediated deposit (could lock it down a bit more by whitelisting users), enable verbose SWORD statements.
    sed -e "s:^swordv2-server.on-behalf-of.enable = .*:swordv2-server.on-behalf-of.enable = true:" -i modules/swordv2-server.cfg
    sed -e "s:^swordv2-server.verbose-description.receipt.enable = .*:swordv2-server.verbose-description.receipt.enable = true:" -i modules/swordv2-server.cfg
}

function import_communities_and_collections() {
    local COMM_COUNT=`perform_query "SELECT count(*) as community_count FROM community" | sed -n 3p | sed -e 's: ::g'`
    local COLL_COUNT=`perform_query "SELECT count(*) as collection_count FROM collection" | sed -n 3p | sed -e 's: ::g'`

    if [ ${COMM_COUNT:-0} == 0 -a ${COLL_COUNT:-0} == 0 ] ;
    then
        (>&2 echo ">>> Populating Community and Collection hierarchy ...")
        cd ${DSPACE_INSTALL_DIR}
        bin/dspace structure-builder -e ${DSPACE_ADMIN_USERNAME} -o /dev/null -f /import.xml
        if [ $? != 0 ] ;
        then
            (>&2 echo ">>> Error creating Communities and Collections!")
            exit 1
        fi
    fi

    return 0
}

function create_dash_metadata_schema() {
    # dash.funder.award
    # dash.funder.identifier
    # dash.funder.name

    local DASH_SCHEMA_NAMESPACE=http://dash.harvard.edu
    local DASH_SCHEMA_SHORTID=dash
    local SCHEMA_REGISTRY_TABLE=metadataschemaregistry
    local FIELD_REGISTRY_TABLE=metadatafieldregistry

    local DASH_SCHEMA_PRESENT=`perform_query "SELECT count(*) from ${SCHEMA_REGISTRY_TABLE} WHERE short_id = '${DASH_SCHEMA_SHORTID}'" | sed -n 3p | sed -e 's: ::g'`
    if [ ${DASH_SCHEMA_PRESENT:-0} == 0 ] ;
    then
        (>&2 echo ">>> Initializing DASH Schema ...")
        perform_query "INSERT INTO ${SCHEMA_REGISTRY_TABLE} (namespace, short_id) VALUES ('${DASH_SCHEMA_NAMESPACE}', '${DASH_SCHEMA_SHORTID}')"
    fi

    local DASH_SCHEMA_ID=`perform_query "SELECT metadata_schema_id from ${SCHEMA_REGISTRY_TABLE} WHERE short_id = '${DASH_SCHEMA_SHORTID}'" | sed -n 3p | sed -e 's: ::g'`
    local DASH_METADATA_ELEMENTS=`perform_query "SELECT count(*) from ${FIELD_REGISTRY_TABLE} WHERE metadata_schema_id = '${DASH_SCHEMA_ID}'" | sed -n 3p | sed -e 's: ::g'`

    if [ ${DASH_METADATA_ELEMENTS:-0} == 0 ] ;
    then
        (>&2 echo ">>> Initializing ${DASH_SCHEMA_SHORTID} metadata registry ...")
        perform_query "INSERT INTO ${FIELD_REGISTRY_TABLE} (metadata_schema_id, element, qualifier) VALUES ('${DASH_SCHEMA_ID}', 'funder', 'award')"
        perform_query "INSERT INTO ${FIELD_REGISTRY_TABLE} (metadata_schema_id, element, qualifier) VALUES ('${DASH_SCHEMA_ID}', 'funder', 'identifier')"
        perform_query "INSERT INTO ${FIELD_REGISTRY_TABLE} (metadata_schema_id, element, qualifier) VALUES ('${DASH_SCHEMA_ID}', 'funder', 'name')"
    fi
    return 0
}

function update_dc_metadata_schema() {
    local FIELD_REGISTRY_TABLE=metadatafieldregistry
    local DC_SCHEMA_ID=1
    local IDENTIFIER_DOI_PRESENT=`perform_query "SELECT count(*) from ${FIELD_REGISTRY_TABLE} WHERE metadata_schema_id = '${DC_SCHEMA_ID}' AND element = 'identifier' and qualifier = 'doi'" | sed -n 3p | sed -e 's: ::g'`
    local SOURCE_JOURNAL_PRESENT=`perform_query "SELECT count(*) from ${FIELD_REGISTRY_TABLE} WHERE metadata_schema_id = '${DC_SCHEMA_ID}' AND element = 'source' and qualifier = 'journal'" | sed -n 3p | sed -e 's: ::g'`
    local SOURCE_VOLUME_PRESENT=`perform_query "SELECT count(*) from ${FIELD_REGISTRY_TABLE} WHERE metadata_schema_id = '${DC_SCHEMA_ID}' AND element = 'source' and qualifier = 'volume'" | sed -n 3p | sed -e 's: ::g'`

    if [ ${IDENTIFIER_DOI_PRESENT:-0} == 0 ] ;
    then
        (>&2 echo ">>> Updating DC metadata registry ...")
        perform_query "INSERT INTO ${FIELD_REGISTRY_TABLE} (metadata_schema_id, element, qualifier) VALUES ('${DC_SCHEMA_ID}', 'identifier', 'doi')"
    fi
    if [ ${SOURCE_JOURNAL_PRESENT:-0} == 0 ] ;
    then
        (>&2 echo ">>> Updating DC metadata registry ...")
        perform_query "INSERT INTO ${FIELD_REGISTRY_TABLE} (metadata_schema_id, element, qualifier) VALUES ('${DC_SCHEMA_ID}', 'source', 'journal')"
    fi
    if [ ${SOURCE_VOLUME_PRESENT:-0} == 0 ] ;
    then
        (>&2 echo ">>> Updating DC metadata registry ...")
        perform_query "INSERT INTO ${FIELD_REGISTRY_TABLE} (metadata_schema_id, element, qualifier) VALUES ('${DC_SCHEMA_ID}', 'source', 'volume')"
    fi
    return 0

}

function create_local_metadata_schema() {
    local FIELD_REGISTRY_TABLE=metadatafieldregistry
    local LOCAL_SCHEMA_ID=4
    local LOCAL_METADATA_ELEMENTS=`perform_query "SELECT count(*) from ${FIELD_REGISTRY_TABLE} WHERE metadata_schema_id = '${LOCAL_SCHEMA_ID}'" | sed -n 3p | sed -e 's: ::g'`

    if [ ${LOCAL_METADATA_ELEMENTS:-0} == 0 ] ;
    then
        (>&2 echo ">>> Initializing local metadata registry ...")
        perform_query "INSERT INTO ${FIELD_REGISTRY_TABLE} (metadata_schema_id, element, qualifier) VALUES ('${LOCAL_SCHEMA_ID}', 'embargo', 'terms')"
        perform_query "INSERT INTO ${FIELD_REGISTRY_TABLE} (metadata_schema_id, element, qualifier) VALUES ('${LOCAL_SCHEMA_ID}', 'embargo', 'lift')"
    fi
    return 0
}
# preserve WORKDIR
WORKDIR=`pwd`

# Configure DSpace from Docker env vars
perform_runtime_config

# Insure database is up and create DSpace admin user and database tables if needed
wait_for_db 2 20
admin_user_exists
if [ $? != 0 ] ;
then
    create_admin_user
fi

if [ $? != 0 ] ;
then
  (>&2 echo ">>> Error initializing the DSpace database.")
  exit -1
fi

# Import communities and collections if they don't already exist
import_communities_and_collections

# Create local metadata schema used to carry embargo metadata fields
create_local_metadata_schema

# Create the Harvard DASH metadata schema
create_dash_metadata_schema

# Add additional elements to the DC metadata schema
update_dc_metadata_schema

# Start jetty
cd ${WORKDIR}

java -Djetty.http.port=${DSPACE_PORT} -Dorg.jboss.logging.provider=slf4j -jar /usr/local/jetty/start.jar