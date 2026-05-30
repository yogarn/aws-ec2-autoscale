watch -n 5 '
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ha-web-asg \
  --region us-east-1 \
  --query "
    AutoScalingGroups[0].Instances[*].{
      InstanceId:InstanceId,
      State:LifecycleState,
      Health:HealthStatus,
      AZ:AvailabilityZone
    }
  " \
  --output table
'
