#!/bin/bash
cd $WORKSPACE

#This file is generated by Nodepool while building snapshots
#It contains credentials to access RabbitMQ and an OpenStack lab
source ~/credentials

sudo ntpdate pool.ntp.org
sudo su -c 'echo "ServerName localhost" >> /etc/apache2/apache2.conf'

python murano-ci/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -rabbitmq_url $RABBITMQ_URL

sudo bash -x murano-ci/infra/deploy_component_new.sh $ZUUL_REF murano-api noop $ZUUL_URL
sudo RUN_DB_SYNC=true bash -x murano-ci/infra/configure_api.sh $RABBITMQ_HOST $RABBITMQ_PORT False murano$BUILD_NUMBER murano$BUILD_NUMBER

git clone https://github.com/Mirantis/tempest
cd tempest
git checkout platform/stable/havana
sudo pip install .

cp etc/tempest.conf.sample etc/tempest.conf
sed -i "s/uri = http:\/\/127.0.0.1:5000\/v2.0\//uri = http:\/\/$KEYSTONE_URL:5000\/v2.0\//" etc/tempest.conf
sed -i "s/admin_username = admin/admin_username = $ADMIN_USERNAME/" etc/tempest.conf
sed -i "s/admin_password = secret/admin_password = $ADMIN_PASSWORD/" etc/tempest.conf
sed -i "s/admin_tenant_name = admin/admin_tenant_name = $ADMIN_TENANT/" etc/tempest.conf
sed -i "s/murano_url = http:\/\/127.0.0.1:8082/murano_url = http:\/\/127.0.0.1:8082\/v1/" etc/tempest.conf
sed -i "s/murano = false/murano = true/" etc/tempest.conf

nosetests -s -v --with-xunit --xunit-file=test_report$BUILD_NUMBER.xml tempest/api/murano/test_murano_envs.py tempest/api/murano/test_murano_services.py tempest/api/murano/test_murano_sessions.py
if [ $? == 1 ]
then
   python $WORKSPACE/murano-ci/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -action delete -rabbitmq_url $RABBITMQ_URL
   exit 1
fi

python $WORKSPACE/murano-ci/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -action delete -rabbitmq_url $RABBITMQ_URL
mv test_report$BUILD_NUMBER.xml ..
