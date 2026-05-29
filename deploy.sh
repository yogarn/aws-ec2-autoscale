#!/bin/bash
set -euo pipefail

REGION="us-east-1"

VPC_ID="vpc-05ac72bedee545793"
SUBNET1="subnet-083df778cfcb5fdef"
SUBNET2="subnet-00f4c9b5dc0b80307"

AMI_ID="ami-05cf1e9f73fbad2e2"
INSTANCE_TYPE="t2.micro"
KEY_NAME="vockey"

SG_NAME="ha-web-sg"
TG_NAME="ha-web-tg"
ALB_NAME="ha-web-alb"
LT_NAME="ha-web-template"
ASG_NAME="ha-web-asg"

echo "=== FULL DEPLOY START ==="

# -------------------------
# 1. SECURITY GROUP
# -------------------------
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "HA Web SG" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' --output text)

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION"
fi

echo "SG: $SG_ID"

# -------------------------
# 2. USER DATA
# -------------------------
cat <<'EOF' > userdata.sh
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# wait for apt lock
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 2
done

apt-get update -y

# install nginx + fcgiwrap
apt-get install -y \
  nginx \
  curl \
  fcgiwrap

# enable fcgiwrap
systemctl enable fcgiwrap
systemctl restart fcgiwrap

# get IMDSv2 token
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# get instance id
INSTANCE_ID=$(curl -s \
  -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

# web root
mkdir -p /var/www/html

# main page
cat <<HTML > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
    <title>HA Web</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            padding: 40px;
            background: #111;
            color: #eee;
        }

        h1 {
            color: #4ade80;
        }

        code {
            background: #222;
            padding: 4px 8px;
        }
    </style>
</head>
<body>
    <h1>Auto Scaling Demo</h1>

    <p>Instance ID:</p>
    <code>$INSTANCE_ID</code>

    <p>
        CPU stress endpoint:
        <a href="/cpu">/cpu</a>
    </p>
</body>
</html>
HTML

# health check endpoint
echo "OK" > /var/www/html/health.html

# CGI directory
mkdir -p /usr/lib/cgi-bin

# CPU intensive CGI script
cat <<'CGI' > /usr/lib/cgi-bin/cpu.sh
#!/bin/bash

echo "Content-Type: text/plain"
echo

echo "Starting CPU burn..."
echo

x=0

for j in {1..80}; do
    for i in {1..500000}; do
        x=$((x + i))
    done
done

echo "Done"
echo "Result: $x"
echo "Timestamp: $(date)"
CGI

chmod +x /usr/lib/cgi-bin/cpu.sh

# nginx config
cat <<'NGINX' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    server_name _;

    root /var/www/html;
    index index.html;

    location = /health.html {
        access_log off;
        return 200 "OK";
    }

    location / {
        try_files $uri $uri/ =404;
    }

    location /cpu {
        gzip off;

        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME /usr/lib/cgi-bin/cpu.sh;

        fastcgi_pass unix:/run/fcgiwrap.socket;
    }
}
NGINX

# validate nginx config
nginx -t

# start services
systemctl enable nginx
systemctl restart nginx

echo "=== USERDATA COMPLETE ==="

EOF

USER_DATA=$(base64 -w 0 userdata.sh)

# -------------------------
# 3. LAUNCH TEMPLATE
# -------------------------
aws ec2 create-launch-template \
  --launch-template-name "$LT_NAME" \
  --launch-template-data "{
    \"ImageId\":\"$AMI_ID\",
    \"InstanceType\":\"$INSTANCE_TYPE\",
    \"KeyName\":\"$KEY_NAME\",
    \"SecurityGroupIds\":[\"$SG_ID\"],
    \"UserData\":\"$USER_DATA\"
  }" \
  --region "$REGION" || true

# -------------------------
# 4. TARGET GROUP
# -------------------------
TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-path "/health.html" \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

# -------------------------
# 5. ALB
# -------------------------
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$ALB_NAME" \
  --subnets "$SUBNET1" "$SUBNET2" \
  --security-groups "$SG_ID" \
  --scheme internet-facing \
  --type application \
  --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN" \
  --region "$REGION"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

# -------------------------
# 6. LISTENER
# -------------------------
aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
  --region "$REGION"

# -------------------------
# 7. AUTO SCALING GROUP
# -------------------------
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --launch-template "LaunchTemplateName=$LT_NAME,Version=1" \
  --min-size 2 \
  --max-size 4 \
  --desired-capacity 2 \
  --vpc-zone-identifier "$SUBNET1,$SUBNET2" \
  --target-group-arns "$TG_ARN" \
  --health-check-type ELB \
  --health-check-grace-period 600 \
  --default-instance-warmup 120 \
  --tags Key=Name,Value=ha-web-instance,PropagateAtLaunch=true \
  --region "$REGION"

# -------------------------
# 8. SCALING POLICIES
# -------------------------
SCALE_OUT=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name scale-out \
  --scaling-adjustment 1 \
  --adjustment-type ChangeInCapacity \
  --cooldown 120 \
  --region "$REGION" \
  --query 'PolicyARN' --output text)

SCALE_IN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name scale-in \
  --scaling-adjustment -1 \
  --adjustment-type ChangeInCapacity \
  --cooldown 180 \
  --region "$REGION" \
  --query 'PolicyARN' --output text)

# -------------------------
# 9. CLOUDWATCH ALARMS
# -------------------------
aws cloudwatch put-metric-alarm \
  --alarm-name cpu-high \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 60 \
  --threshold 70 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
  --alarm-actions "$SCALE_OUT" \
  --region "$REGION"

aws cloudwatch put-metric-alarm \
  --alarm-name cpu-low \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 120 \
  --threshold 30 \
  --comparison-operator LessThanThreshold \
  --evaluation-periods 2 \
  --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
  --alarm-actions "$SCALE_IN" \
  --region "$REGION"

echo ""
echo "ALB: http://$ALB_DNS"
echo "ASG: $ASG_NAME"
echo "DONE."
