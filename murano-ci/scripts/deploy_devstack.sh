#!/bin/bash
# Copyright (c) 2014 Mirantis, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#

# Error trapping first
#---------------------
set -o errexit

CI_ROOT_DIR=$(cd $(dirname "$0") && cd .. && pwd)

# Include of the common functions library file
source "${CI_ROOT_DIR}/scripts/common.inc"
#-----------------

trap 'trap_handler ${?} ${LINENO} ${0}' ERR
trap 'exit_handler ${?}' EXIT
#---------------------

# Enable debug output
#--------------------
PS4='+ [$(date --rfc-3339=seconds)] '
set -o xtrace
#--------------------

# Functions
#-------------------------------------------------------------------------------
function git_clone_devstack() {
    sudo mkdir -p "${STACK_HOME}"
    sudo chown -R jenkins:jenkins "${STACK_HOME}"
    git clone https://github.com/openstack-dev/devstack ${STACK_HOME}/devstack

    pushd ${STACK_HOME}/devstack
    git checkout ${ZUUL_BRANCH} |:
    popd
}

function deploy_devstack() {
    local git_dir=/opt/git

    sudo mkdir -p "${git_dir}/openstack"
    sudo chown -R jenkins:jenkins "${git_dir}/openstack"
    git clone https://github.com/openstack/murano "${git_dir}/openstack/murano"

    if [ "${PROJECT_NAME}" == 'murano' ]; then
        pushd "${git_dir}/openstack/murano"
        git fetch ${ZUUL_URL}/${ZUUL_PROJECT} ${ZUUL_REF} && git checkout FETCH_HEAD
        popd
    else
        pushd "${git_dir}/openstack/murano"
        git checkout ${ZUUL_BRANCH}
        popd
    fi

    cp -Rv ${git_dir}/openstack/murano/contrib/devstack/* ${STACK_HOME}/devstack/

    cd ${STACK_HOME}/devstack

    case "${PROJECT_NAME}" in
        'murano')
            MURANO_REPO=${ZUUL_URL}/${ZUUL_PROJECT}
            MURANO_BRANCH=${ZUUL_REF}
        ;;
        'murano-dashboard')
            MURANO_DASHBOARD_REPO=${ZUUL_URL}/${ZUUL_PROJECT}
            MURANO_DASHBOARD_BRANCH=${ZUUL_REF}
        ;;
        'python-muranoclient')
            MURANO_PYTHONCLIENT_REPO=${ZUUL_URL}/${ZUUL_PROJECT}
            MURANO_PYTHONCLIENT_BRANCH=${ZUUL_REF}
        ;;
    esac

    echo "MURANO_REPO=${MURANO_REPO}"
    echo "MURANO_BRANCH=${MURANO_BRANCH}"
    echo "MURANO_DASHBOARD_REPO=${MURANO_DASHBOARD_REPO}"
    echo "MURANO_DASHBOARD_BRANCH=${MURANO_DASHBOARD_BRANCH}"
    echo "MURANO_PYTHONCLIENT_REPO=${MURANO_PYTHONCLIENT_REPO}"
    echo "MURANO_PYTHONCLIENT_BRANCH=${MURANO_PYTHONCLIENT_BRANCH}"

    cat << EOF > local.conf
[[local|localrc]]
HOST_IP=${OPENSTACK_HOST}           # IP address of OpenStack lab
ADMIN_PASSWORD=${ADMIN_PASSWORD}    # This value doesn't matter
MYSQL_PASSWORD=swordfish            # Random password for MySQL installation
SERVICE_PASSWORD=${ADMIN_PASSWORD}  # Password of service user
SERVICE_TOKEN=.                     # This value doesn't matter
SERVICE_TENANT_NAME=${ADMIN_TENANT}
MURANO_ADMIN_USER=${ADMIN_USERNAME}
RABBIT_HOST=${floating_ip_address}
MURANO_REPO=${MURANO_REPO}
MURANO_BRANCH=${MURANO_BRANCH}
MURANO_DASHBOARD_REPO=${MURANO_DASHBOARD_REPO}
MURANO_DASHBOARD_BRANCH=${MURANO_DASHBOARD_BRANCH}
MURANO_PYTHONCLIENT_REPO=${MURANO_PYTHONCLIENT_REPO}
MURANO_PYTHONCLIENT_BRANCH=${MURANO_PYTHONCLIENT_BRANCH}
RABBIT_PASSWORD=guest
MURANO_RABBIT_VHOST=/
RECLONE=True
SCREEN_LOGDIR=/opt/stack/log/
LOGFILE=\$SCREEN_LOGDIR/stack.sh.log
ENABLED_SERVICES=
enable_service mysql
enable_service rabbit
enable_service horizon
enable_service murano
enable_service murano-api
enable_service murano-engine
enable_service murano-dashboard
EOF

    sudo ./tools/create-stack-user.sh
    if [[ -n "${OVERRIDE_STACK_PASSWORD}" ]]; then
        echo "stack:${OVERRIDE_STACK_PASSWORD}" | sudo chpasswd
    else
        echo 'stack:swordfish' | sudo chpasswd
    fi

    sudo chown -R stack:stack "${STACK_HOME}"

    sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sudo service ssh restart

    sudo su -c "cd ${STACK_HOME}/devstack && ./stack.sh" stack

    # Fix iptables to allow outbound access
    sudo iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
}

function adjust_time_settings(){
    sudo sh -c "echo \"${TZ_STRING}\" > /etc/timezone"
    sudo dpkg-reconfigure -f noninteractive tzdata

    sudo ntpdate -u ru.pool.ntp.org
}
#-------------------------------------------------------------------------------

BUILD_STATUS_ON_EXIT='VM_REUSED'

# Create flags (files to check VM state)
if [ -f ~/build-started ]; then
    echo 'This VM is from previous tests run, terminating build'
    exit 1
else
    touch ~/build-started
fi

BUILD_STATUS_ON_EXIT='PREPARATION_FAILED'

cp ${WORKSPACE}/scripts/templates/empty.template ${WORKSPACE}/index.html

if [ "${KEEP_VM_ALIVE}" == 'true' ]; then
    touch ~/keep-vm-alive
fi

sudo sh -c "echo '127.0.0.1 $(hostname)' >> /etc/hosts"
sudo iptables -F

adjust_time_settings

git_clone_devstack

BUILD_STATUS_ON_EXIT='DEVSTACK_FAILED'

deploy_devstack

BUILD_STATUS_ON_EXIT='DEVSTACK_INSTALLED'

cat << EOF
********************************************************************************
*
*   Fixed IP: ${found_ip_address}
*   Floating IP: ${floating_ip_address}
*   Horizon URL: http://${floating_ip_address}
*   SSH connection string: ssh stack@${floating_ip_address} -oPubkeyAuthentication=no
*
********************************************************************************
EOF
