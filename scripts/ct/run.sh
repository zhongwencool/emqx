#!/usr/bin/env bash

## This script runs CT (and necessary dependencies) in docker container(s)

set -euo pipefail

# ensure dir
cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."

help() {
    echo
    echo "-h|--help:              To display this usage info"
    echo "--app lib_dir/app_name: For which app to run start docker-compose, and run common tests"
    echo "--console:              Start EMQX in console mode but do not run test cases"
    echo "--attach:               Attach to the Erlang docker container without running any test case"
    echo "--stop:                 Stop running containers for the given app"
    echo "--only-up:              Only start the testbed but do not run CT"
    echo "--keep-up:              Keep the testbed running after CT"
    echo "--ci:                   Set this flag in GitHub action to enforce no tests are skipped"
    echo "--:                     If any, all args after '--' are passed to rebar3 ct"
    echo "                        otherwise it runs the entire app's CT"
}

set +e
if docker compose version; then
    DC='docker compose'
elif command -v docker-compose; then
    DC='docker-compose'
else
    echo 'Neither "docker compose" or "docker-compose" are available, stop.'
    exit 1
fi
set -e

WHICH_APP='novalue'
CONSOLE='no'
KEEP_UP='no'
ONLY_UP='no'
ATTACH='no'
STOP='no'
IS_CI='no'
ODBC_REQUEST='no'
while [ "$#" -gt 0 ]; do
    case $1 in
        -h|--help)
            help
            exit 0
            ;;
        --app)
            WHICH_APP="${2%/}"
            shift 2
            ;;
        --only-up)
            ONLY_UP='yes'
            shift 1
            ;;
        --keep-up)
            KEEP_UP='yes'
            shift 1
            ;;
        --attach)
            ATTACH='yes'
            shift 1
            ;;
        --stop)
            STOP='yes'
            shift 1
            ;;
        --console)
            CONSOLE='yes'
            shift 1
            ;;
        --ci)
            IS_CI='yes'
            shift 1
            ;;
        --)
            shift 1
            REBAR3CT="$*"
            shift $#
            ;;
        *)
            echo "unknown option $1"
            exit 1
            ;;
    esac
done

if [ "${WHICH_APP}" = 'novalue' ]; then
    echo "must provide --app arg"
    help
    exit 1
fi

if [[ "${WHICH_APP}" == lib-ee* && (-z "${PROFILE+x}" || "${PROFILE}" != emqx-enterprise) ]]; then
    echo 'You are trying to run an enterprise test case without the emqx-enterprise profile.'
    echo 'This will most likely not work.'
    echo ''
    echo 'Run "export PROFILE=emqx-enterprise" and "make" to fix this'
    exit 1
fi

ERLANG_CONTAINER='erlang'
DOCKER_CT_ENVS_FILE="${WHICH_APP}/docker-ct"

case "${WHICH_APP}" in
    lib-ee*)
        ## ensure enterprise profile when testing lib-ee applications
        export PROFILE='emqx-enterprise'
        ;;
    apps/*)
        if [[ -f "${WHICH_APP}/BSL.txt" ]]; then
          export PROFILE='emqx-enterprise'
        else
          export PROFILE='emqx'
        fi
        ;;
    *)
        export PROFILE="${PROFILE:-emqx}"
        ;;
esac

if [ -f "$DOCKER_CT_ENVS_FILE" ]; then
    # shellcheck disable=SC2002
    CT_DEPS="$(cat "$DOCKER_CT_ENVS_FILE" | xargs)"
fi
CT_DEPS="${ERLANG_CONTAINER} ${CT_DEPS:-}"

FILES=( )

for dep in ${CT_DEPS}; do
    case "${dep}" in
        erlang)
            FILES+=( '.ci/docker-compose-file/docker-compose.yaml' )
            ;;
        toxiproxy)
            FILES+=( '.ci/docker-compose-file/docker-compose-toxiproxy.yaml' )
            ;;
        influxdb)
            FILES+=( '.ci/docker-compose-file/docker-compose-influxdb-tcp.yaml'
                     '.ci/docker-compose-file/docker-compose-influxdb-tls.yaml' )
            ;;
        mongo)
            FILES+=( '.ci/docker-compose-file/docker-compose-mongo-single-tcp.yaml'
                     '.ci/docker-compose-file/docker-compose-mongo-single-tls.yaml' )
            ;;
        mongo_rs_sharded)
            FILES+=( '.ci/docker-compose-file/docker-compose-mongo-replicaset-tcp.yaml'
                     '.ci/docker-compose-file/docker-compose-mongo-sharded-tcp.yaml' )
            ;;
        redis)
            FILES+=( '.ci/docker-compose-file/docker-compose-redis-single-tcp.yaml'
                     '.ci/docker-compose-file/docker-compose-redis-single-tls.yaml'
                     '.ci/docker-compose-file/docker-compose-redis-sentinel-tcp.yaml'
                     '.ci/docker-compose-file/docker-compose-redis-sentinel-tls.yaml' )
            ;;
        redis_cluster)
            FILES+=( '.ci/docker-compose-file/docker-compose-redis-cluster-tcp.yaml'
                     '.ci/docker-compose-file/docker-compose-redis-cluster-tls.yaml' )
            ;;
        mysql)
            FILES+=( '.ci/docker-compose-file/docker-compose-mysql-tcp.yaml'
                     '.ci/docker-compose-file/docker-compose-mysql-tls.yaml' )
            ;;
        pgsql)
            FILES+=( '.ci/docker-compose-file/docker-compose-pgsql-tcp.yaml'
                     '.ci/docker-compose-file/docker-compose-pgsql-tls.yaml' )
            ;;
        kafka)
            FILES+=( '.ci/docker-compose-file/docker-compose-kafka.yaml' )
            ;;
        tdengine)
            FILES+=( '.ci/docker-compose-file/docker-compose-tdengine-restful.yaml' )
            ;;
        clickhouse)
            FILES+=( '.ci/docker-compose-file/docker-compose-clickhouse.yaml' )
            ;;
        dynamo)
            FILES+=( '.ci/docker-compose-file/docker-compose-dynamo.yaml' )
            ;;
        rocketmq)
            FILES+=( '.ci/docker-compose-file/docker-compose-rocketmq.yaml' )
            ;;
        cassandra)
            FILES+=( '.ci/docker-compose-file/docker-compose-cassandra.yaml' )
            ;;
        sqlserver)
            ODBC_REQUEST='yes'
            FILES+=( '.ci/docker-compose-file/docker-compose-sqlserver.yaml' )
            ;;
        opents)
            FILES+=( '.ci/docker-compose-file/docker-compose-opents.yaml' )
            ;;
        pulsar)
            FILES+=( '.ci/docker-compose-file/docker-compose-pulsar.yaml' )
            ;;
        oracle)
            FILES+=( '.ci/docker-compose-file/docker-compose-oracle.yaml' )
            ;;
        iotdb)
            FILES+=( '.ci/docker-compose-file/docker-compose-iotdb.yaml' )
            ;;
        rabbitmq)
            FILES+=( '.ci/docker-compose-file/docker-compose-rabbitmq.yaml' )
            ;;
        *)
            echo "unknown_ct_dependency $dep"
            exit 1
            ;;
    esac
done

if [ "$ODBC_REQUEST" = 'yes' ]; then
    INSTALL_ODBC="./scripts/install-msodbc-driver.sh"
else
    INSTALL_ODBC="echo 'msodbc driver not requested'"
fi

F_OPTIONS=""

for file in "${FILES[@]}"; do
    F_OPTIONS="$F_OPTIONS -f $file"
done

DOCKER_USER="$(id -u)"
export DOCKER_USER

TTY=''
if [[ -t 1 ]]; then
    TTY='-t'
fi

# ensure directory with secrets is created by current user before running compose
mkdir -p /tmp/emqx-ci/emqx-shared-secret

if [ "$STOP" = 'no' ]; then
    # some left-over log file has to be deleted before a new docker-compose up
    rm -f '.ci/docker-compose-file/redis/*.log'
    set +e
    # shellcheck disable=2086 # no quotes for F_OPTIONS
    $DC $F_OPTIONS up -d --build --remove-orphans
    RESULT=$?
    if [ $RESULT -ne 0 ]; then
        mkdir -p _build/test/logs
        LOG='_build/test/logs/docker-compose.log'
        echo "Dumping docker-compose log to $LOG"
        # shellcheck disable=2086 # no quotes for F_OPTIONS
        $DC $F_OPTIONS logs --no-color --timestamps > "$LOG"
        exit 1
    fi
    set -e
fi

# rebar, mix and hex cache directory need to be writable by $DOCKER_USER
docker exec -i $TTY -u root:root "$ERLANG_CONTAINER" bash -c "mkdir -p /.cache /.hex /.mix && chown $DOCKER_USER /.cache /.hex /.mix"
# need to initialize .erlang.cookie manually here because / is not writable by $DOCKER_USER
docker exec -i $TTY -u root:root "$ERLANG_CONTAINER" bash -c "openssl rand -base64 16 > /.erlang.cookie && chown $DOCKER_USER /.erlang.cookie && chmod 0400 /.erlang.cookie"
# the user must exist inside the container for `whoami` to work
docker exec -i $TTY -u root:root "$ERLANG_CONTAINER" bash -c "useradd --uid $DOCKER_USER -M -d / emqx" || true
docker exec -i $TTY -u root:root "$ERLANG_CONTAINER" bash -c "chown -R $DOCKER_USER /var/lib/secret" || true
docker exec -i $TTY -u root:root "$ERLANG_CONTAINER" bash -c "$INSTALL_ODBC" || true

if [ "$ONLY_UP" = 'yes' ]; then
    exit 0
fi

set +e

if [ "$STOP" = 'yes' ]; then
    # shellcheck disable=2086 # no quotes for F_OPTIONS
    $DC $F_OPTIONS down --remove-orphans
elif [ "$ATTACH" = 'yes' ]; then
    docker exec -it "$ERLANG_CONTAINER" bash
elif [ "$CONSOLE" = 'yes' ]; then
    docker exec -e PROFILE="$PROFILE" -i $TTY "$ERLANG_CONTAINER" bash -c "make run"
else
    if [ -z "${REBAR3CT:-}" ]; then
        docker exec -e IS_CI="$IS_CI" -e PROFILE="$PROFILE" -i $TTY "$ERLANG_CONTAINER" bash -c "BUILD_WITHOUT_QUIC=1 make ${WHICH_APP}-ct"
    else
        docker exec -e IS_CI="$IS_CI" -e PROFILE="$PROFILE" -i $TTY "$ERLANG_CONTAINER" bash -c "./rebar3 ct $REBAR3CT"
    fi
    RESULT=$?
    if [ "$RESULT" -ne 0 ]; then
        LOG='_build/test/logs/docker-compose.log'
        echo "Dumping docker-compose log to $LOG"
        # shellcheck disable=2086 # no quotes for F_OPTIONS
        $DC $F_OPTIONS logs --no-color --timestamps > "$LOG"
    fi
    if [ "$KEEP_UP" != 'yes' ]; then
        # shellcheck disable=2086 # no quotes for F_OPTIONS
        $DC $F_OPTIONS down
    fi
    exit "$RESULT"
fi
