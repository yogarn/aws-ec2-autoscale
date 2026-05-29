#!/bin/bash

set -e

# ==========================================
# VARIABLES
# ==========================================

REGION="us-east-1"

LOAD_BALANCER_NAME="ha-web-alb"
TARGET_GROUP_NAME="ha-web-tg"
AUTO_SCALING_GROUP_NAME="ha-web-asg"
LAUNCH_TEMPLATE_NAME="ha-web-template"
SECURITY_GROUP_NAME="ha-web-sg"

# ==========================================
# FETCH RESOURCE IDS
# ==========================================

echo "Fetching resource identifiers..."

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names $LOAD_BALANCER_NAME \
  --region $REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || echo "None")

TG_ARN=$(aws elbv2 describe-target-groups \
  --names $TARGET_GROUP_NAME \
  --region $REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || echo "None")

SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=$SECURITY_GROUP_NAME \
  --region $REGION \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "None")

echo "=========================================="
echo "RESOURCE SUMMARY"
echo "=========================================="
echo "ALB ARN        : $ALB_ARN"
echo "TG ARN         : $TG_ARN"
echo "SECURITY GROUP : $SG_ID"
echo "=========================================="

# ==========================================
# FETCH INSTANCE IDS BEFORE DELETE
# ==========================================

echo "Fetching ASG instance IDs..."

INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $AUTO_SCALING_GROUP_NAME \
  --region $REGION \
  --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
  --output text 2>/dev/null || true)

echo "Instances: $INSTANCE_IDS"

# ==========================================
# DELETE AUTO SCALING GROUP
# ==========================================

echo "Deleting Auto Scaling Group..."

aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name $AUTO_SCALING_GROUP_NAME \
  --min-size 0 \
  --desired-capacity 0 \
  --region $REGION || true

aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name $AUTO_SCALING_GROUP_NAME \
  --force-delete \
  --region $REGION || true

# ==========================================
# WAIT FOR EC2 TERMINATION
# ==========================================

if [ ! -z "$INSTANCE_IDS" ]; then
  echo "Waiting for EC2 instances to terminate..."

  aws ec2 wait instance-terminated \
    --instance-ids $INSTANCE_IDS \
    --region $REGION

  echo "All ASG EC2 instances terminated."
else
  echo "No ASG EC2 instances found."
fi

# ==========================================
# TERMINATE ORPHAN INSTANCES
# ==========================================

echo "Checking for orphan EC2 instances..."

if [ "$SG_ID" != "None" ]; then

  ORPHAN_IDS=$(aws ec2 describe-instances \
    --filters Name=instance.group-id,Values=$SG_ID \
              Name=instance-state-name,Values=running,pending,stopped \
    --region $REGION \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text 2>/dev/null || true)

  if [ ! -z "$ORPHAN_IDS" ]; then

    echo "Terminating orphan instances..."
    echo "$ORPHAN_IDS"

    aws ec2 terminate-instances \
      --instance-ids $ORPHAN_IDS \
      --region $REGION > /dev/null

    aws ec2 wait instance-terminated \
      --instance-ids $ORPHAN_IDS \
      --region $REGION

    echo "Orphan instances terminated."

  else
    echo "No orphan instances found."
  fi
fi

# ==========================================
# DELETE LISTENERS
# ==========================================

echo "Deleting ALB listeners..."

if [ "$ALB_ARN" != "None" ] && [ ! -z "$ALB_ARN" ]; then

  LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --load-balancer-arn $ALB_ARN \
    --region $REGION \
    --query 'Listeners[*].ListenerArn' \
    --output text 2>/dev/null || true)

  for LISTENER in $LISTENER_ARNS
  do
    echo "Deleting listener: $LISTENER"

    aws elbv2 delete-listener \
      --listener-arn $LISTENER \
      --region $REGION || true
  done
fi

# ==========================================
# DELETE LOAD BALANCER
# ==========================================

echo "Deleting Load Balancer..."

if [ "$ALB_ARN" != "None" ] && [ ! -z "$ALB_ARN" ]; then

  aws elbv2 delete-load-balancer \
    --load-balancer-arn $ALB_ARN \
    --region $REGION || true

  echo "Waiting for Load Balancer deletion..."

  while true; do

    EXISTS=$(aws elbv2 describe-load-balancers \
      --load-balancer-arns $ALB_ARN \
      --region $REGION \
      --query 'LoadBalancers[0].State.Code' \
      --output text 2>/dev/null || echo "deleted")

    if [ "$EXISTS" = "deleted" ]; then
      echo "Load Balancer deleted."
      break
    fi

    echo "Still deleting ALB..."
    sleep 10

  done
fi

# ==========================================
# DELETE TARGET GROUP
# ==========================================

echo "Deleting Target Group..."

if [ "$TG_ARN" != "None" ] && [ ! -z "$TG_ARN" ]; then

  aws elbv2 delete-target-group \
    --target-group-arn $TG_ARN \
    --region $REGION || true

  echo "Target Group deleted."
fi

# ==========================================
# DELETE CLOUDWATCH ALARMS
# ==========================================

echo "Deleting CloudWatch alarms..."

aws cloudwatch delete-alarms \
  --alarm-names cpu-high-alarm cpu-low-alarm \
  --region $REGION || true

# ==========================================
# DELETE LAUNCH TEMPLATE
# ==========================================

echo "Deleting Launch Template..."

aws ec2 delete-launch-template \
  --launch-template-name $LAUNCH_TEMPLATE_NAME \
  --region $REGION || true

# ==========================================
# WAIT FOR ENI DETACH
# ==========================================

if [ "$SG_ID" != "None" ]; then

  echo "Waiting for ENI detach..."

  while true; do

    ENI_COUNT=$(aws ec2 describe-network-interfaces \
      --filters Name=group-id,Values=$SG_ID \
      --region $REGION \
      --query 'length(NetworkInterfaces)' \
      --output text 2>/dev/null || echo "0")

    if [ "$ENI_COUNT" = "0" ]; then
      echo "All ENIs detached."
      break
    fi

    echo "ENI still attached: $ENI_COUNT"

    sleep 10

  done
fi

# ==========================================
# DELETE SECURITY GROUP
# ==========================================

echo "Deleting Security Group..."

if [ "$SG_ID" != "None" ] && [ ! -z "$SG_ID" ]; then

  aws ec2 delete-security-group \
    --group-id $SG_ID \
    --region $REGION || true

  echo "Security Group deleted."
fi

# ==========================================
# CLEAN LOCAL FILES
# ==========================================

rm -f userdata.sh

# ==========================================
# FINISHED
# ==========================================

echo "=========================================="
echo "ALL RESOURCES DESTROYED SUCCESSFULLY"
echo "=========================================="