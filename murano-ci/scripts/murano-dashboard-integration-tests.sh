#!/bin/bash
cd $WORKSPACE

#This file is generated by Nodepool while building snapshots
#It contains credentials to access RabbitMQ and an OpenStack lab
source ~/credentials

export DISPLAY=:22
screen -dmS display sudo Xvfb -fp /usr/share/fonts/X11/misc/ :22 -screen 0 1024x768x16
sudo iptables -F
sudo ntpdate pool.ntp.org
sudo su -c 'echo "ServerName localhost" >> /etc/apache2/apache2.conf'
ADDR=`ifconfig eth0| awk -F ' *|:' '/inet addr/{print $4}'`

git clone https://git.openstack.org/stackforge/murano-tests

python murano-ci/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -rabbitmq_url $RABBITMQ_URL

sudo bash -x murano-ci/infra/deploy_component_new.sh $ZUUL_REF murano-dashboard $KEYSTONE_URL $ZUUL_URL
sudo RUN_DB_SYNC=true bash -x murano-ci/infra/configure_api.sh $RABBITMQ_HOST $RABBITMQ_PORT False murano$BUILD_NUMBER murano$BUILD_NUMBER

cd murano-tests/muranodashboard-tests
sed "s%keystone_url = http://127.0.0.1:5000/v2.0/%keystone_url = http://$KEYSTONE_URL:5000/v2.0/%g" -i config/config_file.conf
sed "s%horizon_url = http://127.0.0.1/horizon%horizon_url = http://$ADDR/horizon%g" -i config/config_file.conf
sed "s%murano_url = http://127.0.0.1:8082%murano_url = http://$ADDR:8082%g" -i config/config_file.conf
sed "s%user = WebTestUser%user = $ADMIN_USERNAME%g" -i config/config_file.conf
sed "s%password = swordfish%password = $ADMIN_PASSWORD%g" -i config/config_file.conf
sed "s%tenant = WebTestProject%tenant = $ADMIN_TENANT%g" -i config/config_file.conf
sed "s%tomcat_repository = git_repo_for_tomcat%tomcat_repository = https://github.com/sergmelikyan/hello-world-servlet%g" -i config/config_file.conf

git clone https://github.com/murano-project/murano-app-incubator
cd murano-app-incubator
sudo bash make-package.sh io.murano.apps.PostgreSql
sudo bash make-package.sh io.murano.apps.apache.Apache
sudo bash make-package.sh io.murano.apps.apache.Tomcat
sudo bash make-package.sh io.murano.apps.linux.Telnet
sudo bash make-package.sh io.murano.windows.ActiveDirectory
cd ..

nosetests sanity_check --nologcapture
if [ $? == 1 ]
then
   python $WORKSPACE/murano-ci/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -action delete -rabbitmq_url $RABBITMQ_URL
   exit 1
fi
python $WORKSPACE/murano-ci/infra/RabbitMQ.py -username murano$BUILD_NUMBER -vhostname murano$BUILD_NUMBER -action delete -rabbitmq_url $RABBITMQ_URL
