#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -x

hostname "$STACK_NAME"
mkdir -p /data/logstash
chmod a+rw /data/logstash

# set full SG list
instance_id="$(curl http://169.254.169.254/latest/meta-data/instance-id)"
aws --region "$REGION" ec2 modify-instance-attribute \
  --instance-id "$instance_id" \
  --groups $KIBANA_SECURITY_GROUP $EXTRA_SECURITY_GROUPS

function elasticsearch_is_unreachable() {
  curl "$ELASTICSEARCH_ENDPOINT" | grep 'not authorized'
}

# try curling the endpoint, if it fails we assume that the access policy needs updating
if elasticsearch_is_unreachable ; then

read -r -d '' POLICY <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "AWS": "*"
      },
      "Action": "es:*",
      "Condition": {
        "IpAddress": {
          "aws:SourceIp": [
            "$(curl http://169.254.169.254/latest/meta-data/public-ipv4)"
          ]
        }
      },
      "Resource": ["$ELASTICSEARCH_ARN/*", "$ELASTICSEARCH_ARN/", "$ELASTICSEARCH_ARN"]
    }
  ]
}
EOF

  aws --region "$REGION" es update-elasticsearch-domain-config \
    --domain-name "$ELASTICSEARCH_DOMAIN_NAME" \
    --access-policies "$POLICY"

  # now we need to wait for about 10 minutes while the cluster is updated
  while elasticsearch_is_unreachable ; do
    sleep 60
  done
fi

md5_before=$(find /opt/docker-elk/logstash/config/ -type f -exec md5sum {} \; | sort -k 2 | md5sum | cut -f1 -d' ')
# sync logstash config bucket
aws --region "$REGION" s3 sync "s3://$S3_BUCKET/" "/opt/docker-elk/logstash/config/"
md5_after=$(find /opt/docker-elk/logstash/config/ -type f -exec md5sum {} \; | sort -k 2 | md5sum | cut -f1 -d' ')

# install Ruby and AWS SDK for ERB in config files
sudo apt-get install -y ruby2.0
gem install aws-sdk
gem install bundler

# process ERB files
ruby <<EOF
require 'erb'
Dir.glob('/opt/docker-elk/logstash/config/*.erb').each do |f|
  puts "Interpolating ERB file #{f}"
  output_name = f.gsub('.erb', '')
  result = ERB.new(File.read(f)).result binding
  File.write(output_name, result)
  File.delete(f)
end
EOF

# add hourly cron script to refresh config
CRON_PATH=/etc/cron.hourly/refresh-logstash
cat >"$CRON_PATH" <<EOF
#!/bin/sh
/usr/local/bin/cfn-init -v --region us-east-1 --stack $STACK_NAME --resource DockerElkInstance -c default
EOF

# add curl helper for querying the ES instance
cat >"/usr/local/bin/curl-es.sh" <<EOF
#!/bin/bash
location=\$1
shift
/usr/bin/curl "\$@" "$ELASTICSEARCH_ENDPOINT/\$location"
EOF

# Optionally install datadog and ES monitoring
if [[ -n "$DD_API_KEY" ]] ; then
  bash -c "$(curl -L https://raw.githubusercontent.com/DataDog/dd-agent/master/packaging/datadog-agent/source/install_agent.sh)"

cat >"/etc/dd-agent/conf.d/elastic.yaml" <<EOF
init_config:

instances:
  - url: $ELASTICSEARCH_ENDPOINT
EOF
  /etc/init.d/datadog-agent restart
fi

chmod +x "/usr/local/bin/curl-es.sh"

# pull/build images as needed
docker-compose -f docker-compose-production.yml pull
docker-compose -f docker-compose-production.yml build

# only stop the containers if the config was changed after sync
if [[ "$md5_before" != "$md5_after" ]] ; then docker-compose -f docker-compose-production.yml down ; fi

# ensure all containers are running
docker-compose -f docker-compose-production.yml up -d