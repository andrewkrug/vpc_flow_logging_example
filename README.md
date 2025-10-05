# VPC Flow Logs Examples

This repository contains AWS CloudFormation templates for setting up VPC Flow Logs, a feature that captures information about the IP traffic going to and from network interfaces in your VPC.

## What are VPC Flow Logs?

VPC Flow Logs allow you to monitor and troubleshoot network traffic in your AWS Virtual Private Cloud (VPC). They capture metadata about the traffic flowing through your network, including:

- Source and destination IP addresses
- Source and destination ports
- Protocol (TCP, UDP, ICMP, etc.)
- Number of packets and bytes transferred
- Whether the traffic was accepted or rejected by security groups/network ACLs
- Timestamps

Flow logs are essential for:
- **Security analysis**: Detecting suspicious traffic patterns or unauthorized access attempts
- **Network troubleshooting**: Diagnosing connectivity issues
- **Compliance**: Meeting audit requirements for network traffic monitoring
- **Cost optimization**: Understanding traffic patterns to optimize data transfer costs

**Official AWS Documentation**: [VPC Flow Logs User Guide](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html)

## Templates Overview

This repository contains two different approaches for collecting VPC Flow Logs:

### 1. VPC Flow Logs to CloudWatch (`vpc-flow-logs-to-cloudwatch/`)

Sends flow logs to CloudWatch Logs for real-time monitoring and short-term retention.

**Best for**:
- Real-time monitoring and alerting
- Quick troubleshooting sessions
- Development and testing environments
- Short-term retention (up to 10 years, but typically much less)

### 2. VPC Flow Logs to S3 (`vpc-flow-logs-to-s3/`)

Stores flow logs in S3 buckets for long-term storage and analysis.

**Best for**:
- Long-term archival and compliance
- Cost-effective storage of large volumes of logs
- Advanced analytics with tools like Amazon Athena
- Multi-account organizations
- Forensic analysis

---

## Template 1: VPC Flow Logs to CloudWatch

### Prerequisites

- An AWS account with appropriate permissions
- An existing VPC (note its VPC ID)
- AWS CLI installed and configured, OR access to the AWS Console

### Deployment Steps

#### Option A: Using AWS Console

1. **Navigate to CloudFormation**:
   - Open the [AWS CloudFormation Console](https://console.aws.amazon.com/cloudformation/)
   - Click "Create stack" → "With new resources (standard)"

2. **Upload the template**:
   - Select "Upload a template file"
   - Click "Choose file" and select `vpc-flow-logs-to-cloudwatch/flow-logs.yml`
   - Click "Next"

3. **Configure stack parameters**:
   - **Stack name**: Enter a descriptive name (e.g., `my-vpc-flow-logs-cloudwatch`)
   - **VpcId**: Enter your VPC ID (format: `vpc-xxxxxxxxxxxxxxxxx`)
     - To find your VPC ID: Go to [VPC Console](https://console.aws.amazon.com/vpc/) → "Your VPCs"
   - **RetentionInDays**: Choose how long to keep logs (default: 14 days)
   - **TrafficType**: Select what traffic to log:
     - `ALL`: Both accepted and rejected traffic (recommended for beginners)
     - `ACCEPT`: Only successful connections
     - `REJECT`: Only blocked traffic
   - Click "Next"

4. **Configure stack options**:
   - (Optional) Add tags for organization
   - Click "Next"

5. **Review and create**:
   - Review your settings
   - Check the box acknowledging IAM resource creation
   - Click "Submit"

6. **Wait for completion**:
   - Wait for the stack status to show `CREATE_COMPLETE` (usually 1-2 minutes)

#### Option B: Using AWS CLI

```bash
aws cloudformation create-stack \
  --stack-name my-vpc-flow-logs-cloudwatch \
  --template-body file://vpc-flow-logs-to-cloudwatch/flow-logs.yml \
  --parameters \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxxxxxxxxxxxxxx \
    ParameterKey=RetentionInDays,ParameterValue=14 \
    ParameterKey=TrafficType,ParameterValue=ALL \
  --capabilities CAPABILITY_IAM
```

Replace `vpc-xxxxxxxxxxxxxxxxx` with your actual VPC ID.

### Viewing Your Flow Logs

1. **Navigate to CloudWatch Logs**:
   - Open the [CloudWatch Console](https://console.aws.amazon.com/cloudwatch/)
   - Click "Logs" → "Log groups" in the left sidebar

2. **Find your log group**:
   - Look for a log group created by your stack (the name will be in the stack outputs)
   - Click on the log group name

3. **View log streams**:
   - You'll see log streams for each network interface in your VPC
   - Click on a stream to view the actual flow log entries
   - **Note**: It may take 5-15 minutes for flow logs to start appearing after creation

4. **Understanding the log format**:
   ```
   2 123456789010 eni-1235b8ca123456789 172.31.16.139 172.31.16.21 20641 22 6 20 4249 1418530010 1418530070 ACCEPT OK
   ```

   Fields (in order):
   - Version, Account ID, Interface ID, Source IP, Destination IP, Source Port, Destination Port, Protocol, Packets, Bytes, Start Time, End Time, Action, Log Status

**CloudWatch Logs Documentation**: [Working with Log Groups and Streams](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/Working-with-log-groups-and-streams.html)

---

## Template 2: VPC Flow Logs to S3

This template (`flow-logs-s3.yml`) is a flexible, all-in-one solution that can:
- Create a new S3 bucket with flow logs enabled, OR
- Use an existing S3 bucket for flow logs
- Configure lifecycle policies for cost optimization
- Enable versioning and object lock for compliance

### Prerequisites

- An existing VPC (note its VPC ID)
- AWS CLI installed and configured, OR access to the AWS Console

### Deployment Options

The template supports two main use cases:

#### Option A: Create New Bucket (Recommended for Beginners)

This option creates everything you need in a single step.

**Using AWS Console**:

1. Navigate to [CloudFormation Console](https://console.aws.amazon.com/cloudformation/)
2. Create stack → Upload `vpc-flow-logs-to-s3/flow-logs-s3.yml`
3. Configure parameters:
   - **Stack name**: `my-vpc-flow-logs-s3`
   - **VpcId**: Your VPC ID (e.g., `vpc-xxxxxxxxxxxxxxxxx`)
   - **TrafficType**: `ALL` (recommended)
   - **CreateBucket**: `Yes`
   - **BucketName**: Leave empty for auto-generated name, or specify a unique name
   - **EnableLifecyclePolicy**: `Yes` (recommended for cost savings)
   - **RetentionInDays**: `90` (how long to keep logs before deletion)
   - **GlacierTransitionDays**: `30` (move to cheaper Glacier storage after 30 days, or `0` to disable)
   - **GlacierRetentionDays**: `365` (keep in Glacier for 1 year)
   - **EnableVersioning**: `Yes` (recommended for data protection)
   - **ObjectLock**: `No` (use `Yes` only for strict compliance requirements)
4. Click through and create the stack

**Using AWS CLI**:
```bash
aws cloudformation create-stack \
  --stack-name my-vpc-flow-logs-s3 \
  --template-body file://vpc-flow-logs-to-s3/flow-logs-s3.yml \
  --parameters \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxxxxxxxxxxxxxx \
    ParameterKey=TrafficType,ParameterValue=ALL \
    ParameterKey=CreateBucket,ParameterValue=Yes \
    ParameterKey=BucketName,ParameterValue=my-unique-flow-logs-bucket \
    ParameterKey=EnableLifecyclePolicy,ParameterValue=Yes \
    ParameterKey=RetentionInDays,ParameterValue=90 \
    ParameterKey=GlacierTransitionDays,ParameterValue=30 \
    ParameterKey=EnableVersioning,ParameterValue=Yes \
    ParameterKey=ObjectLock,ParameterValue=No
```

#### Option B: Use Existing Bucket

If you already have an S3 bucket configured for flow logs:

**Important**: Your existing bucket must have the proper bucket policy. See "Setting Up an Existing S3 Bucket" below.

**Using AWS CLI**:
```bash
aws cloudformation create-stack \
  --stack-name my-vpc-flow-logs-s3 \
  --template-body file://vpc-flow-logs-to-s3/flow-logs-s3.yml \
  --parameters \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxxxxxxxxxxxxxx \
    ParameterKey=TrafficType,ParameterValue=ALL \
    ParameterKey=CreateBucket,ParameterValue=No \
    ParameterKey=BucketName,ParameterValue=my-existing-bucket-name
```

### Setting Up an Existing S3 Bucket

If using Option B (existing bucket), you must configure the bucket policy manually:

1. **Navigate to your S3 bucket** in the [S3 Console](https://console.aws.amazon.com/s3/)
2. Go to **Permissions** → **Bucket Policy**
3. Add this policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSLogDeliveryAclCheck",
      "Effect": "Allow",
      "Principal": {
        "Service": "delivery.logs.amazonaws.com"
      },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME"
    },
    {
      "Sid": "AWSLogDeliveryWrite",
      "Effect": "Allow",
      "Principal": {
        "Service": "delivery.logs.amazonaws.com"
      },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control"
        }
      }
    }
  ]
}
```

Replace `YOUR-BUCKET-NAME` with your actual bucket name.

### Viewing S3 Flow Logs

1. **Navigate to your S3 bucket**:
   - Open the [S3 Console](https://console.aws.amazon.com/s3/)
   - Click on your flow logs bucket

2. **Browse the log files**:
   - Logs are organized by: `AWSLogs/{account-id}/vpcflowlogs/{region}/{year}/{month}/{day}/`
   - Files are in compressed gzip format (`.gz`)

3. **Download and view a log file**:
   ```bash
   aws s3 cp s3://my-bucket/AWSLogs/123456789010/vpcflowlogs/us-east-1/2024/01/15/123456789010_vpcflowlogs_us-east-1_fl-1234abcd_20240115T0000Z_hash.log.gz .
   gunzip *.log.gz
   cat *.log
   ```

---

## Analyzing Flow Logs with Amazon Athena

Amazon Athena allows you to query your S3-stored flow logs using SQL, making it easy to analyze traffic patterns, detect anomalies, and generate reports.

**Athena Documentation**: [Querying Amazon VPC Flow Logs](https://docs.aws.amazon.com/athena/latest/ug/vpc-flow-logs.html)

### Prerequisites

- VPC Flow Logs already flowing to S3 (Template 2 deployed with S3 destination)
- S3 bucket for Athena query results

### Step 1: Set Up Athena

1. **Create a query results bucket** (if you don't have one):
   ```bash
   aws s3 mb s3://my-athena-query-results-unique-name
   ```

2. **Navigate to Athena Console**:
   - Open [Amazon Athena Console](https://console.aws.amazon.com/athena/)

3. **Configure query result location**:
   - Click "Settings" or "Manage"
   - Set "Query result location" to `s3://my-athena-query-results-unique-name/`
   - Click "Save"

### Step 2: Create a Database

In the Athena query editor, run:

```sql
CREATE DATABASE IF NOT EXISTS vpc_flow_logs;
```

### Step 3: Create a Table for Flow Logs

This table definition matches the default VPC Flow Logs format:

```sql
CREATE EXTERNAL TABLE IF NOT EXISTS vpc_flow_logs.flow_logs (
  version int,
  account_id string,
  interface_id string,
  srcaddr string,
  dstaddr string,
  srcport int,
  dstport int,
  protocol bigint,
  packets bigint,
  bytes bigint,
  start bigint,
  end bigint,
  action string,
  log_status string
)
PARTITIONED BY (
  dt string
)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY ' '
LOCATION 's3://my-vpc-flow-logs-bucket-unique-name/AWSLogs/{account-id}/vpcflowlogs/{region}/'
TBLPROPERTIES ("skip.header.line.count"="1");
```

**Important**: Replace the `LOCATION` with your actual S3 bucket path:
- `{account-id}`: Your 12-digit AWS account ID
- `{region}`: Your AWS region (e.g., `us-east-1`)

### Step 4: Load Partitions

To improve query performance and reduce costs, add partitions for your data:

```sql
ALTER TABLE vpc_flow_logs.flow_logs
ADD PARTITION (dt='2024-01-15')
LOCATION 's3://my-vpc-flow-logs-bucket-unique-name/AWSLogs/123456789010/vpcflowlogs/us-east-1/2024/01/15/';
```

**Tip**: Repeat for each day you want to query, or use [partition projection](https://docs.aws.amazon.com/athena/latest/ug/partition-projection.html) to automate this.

### Step 5: Query Your Flow Logs

Now you can run SQL queries! Here are some useful examples:

#### Example 1: View recent flow logs

```sql
SELECT *
FROM vpc_flow_logs.flow_logs
LIMIT 100;
```

#### Example 2: Find top talkers (by bytes transferred)

```sql
SELECT srcaddr, dstaddr, SUM(bytes) as total_bytes
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
GROUP BY srcaddr, dstaddr
ORDER BY total_bytes DESC
LIMIT 20;
```

#### Example 3: Identify rejected traffic (potential security issues)

```sql
SELECT srcaddr, dstaddr, srcport, dstport, protocol, COUNT(*) as reject_count
FROM vpc_flow_logs.flow_logs
WHERE action = 'REJECT'
  AND dt = '2024-01-15'
GROUP BY srcaddr, dstaddr, srcport, dstport, protocol
ORDER BY reject_count DESC
LIMIT 50;
```

#### Example 4: Find SSH connections

```sql
SELECT srcaddr, dstaddr, start, end, bytes, packets
FROM vpc_flow_logs.flow_logs
WHERE dstport = 22
  AND protocol = 6  -- TCP
  AND action = 'ACCEPT'
  AND dt = '2024-01-15';
```

#### Example 5: Traffic by hour

```sql
SELECT
  DATE_FORMAT(FROM_UNIXTIME(start), '%Y-%m-%d %H:00') as hour,
  SUM(bytes) as total_bytes,
  SUM(packets) as total_packets,
  COUNT(*) as flow_count
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
GROUP BY DATE_FORMAT(FROM_UNIXTIME(start), '%Y-%m-%d %H:00')
ORDER BY hour;
```

#### Example 6: Find traffic from specific IP

```sql
SELECT *
FROM vpc_flow_logs.flow_logs
WHERE srcaddr = '192.168.1.100'
  AND dt = '2024-01-15'
ORDER BY start DESC;
```

### Understanding Protocol Numbers

The `protocol` field uses [IANA protocol numbers](https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml):
- `6` = TCP
- `17` = UDP
- `1` = ICMP

### Cost Optimization Tips for Athena

- **Use partitions**: Always specify `dt` in your WHERE clause to scan less data
- **Limit results**: Use `LIMIT` when exploring data
- **Use columnar formats**: Consider converting logs to Parquet format for better performance
- **Monitor query costs**: Athena charges $5 per TB of data scanned

**Athena Pricing**: [Amazon Athena Pricing](https://aws.amazon.com/athena/pricing/)

---

## Troubleshooting

### Flow logs aren't appearing

- **Wait 10-15 minutes**: Flow logs have a delay before they start appearing
- **Check VPC has traffic**: Flow logs only capture active traffic
- **Verify permissions**: Ensure IAM roles/bucket policies are correct
- **Check flow log status**: In EC2 Console → VPC → Flow Logs, verify status is "Active"

### CloudFormation stack creation failed

- **Check permissions**: Ensure your AWS user/role has permission to create IAM roles and flow logs
- **Verify VPC exists**: Confirm your VPC ID is correct
- **Check bucket permissions**: For S3 templates, ensure bucket policy is correct

### Athena queries failing

- **Check S3 path**: Verify the `LOCATION` in your table definition matches your actual S3 structure
- **Verify data exists**: Ensure flow logs have been written to S3
- **Check partitions**: Make sure you've added partitions for the dates you're querying
- **Review query syntax**: Check for SQL errors in the Athena console

---

## Additional Resources

- **VPC Flow Logs Official Guide**: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html
- **Flow Logs Record Examples**: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-records-examples.html
- **CloudFormation Documentation**: https://docs.aws.amazon.com/cloudformation/
- **Amazon Athena User Guide**: https://docs.aws.amazon.com/athena/latest/ug/what-is.html
- **VPC Flow Logs Pricing**: https://aws.amazon.com/cloudwatch/pricing/ (CloudWatch) and https://aws.amazon.com/s3/pricing/ (S3)

---

## License

This project is licensed under the MIT License. See the LICENSE file for details.

---

## Security Best Practices

1. **Enable encryption**: Use S3 encryption and CloudWatch Logs encryption for sensitive data
2. **Restrict access**: Use IAM policies to limit who can view flow logs
3. **Monitor costs**: Flow logs can generate large volumes of data; monitor your usage
4. **Retention policies**: Set appropriate retention periods to balance cost and compliance needs
5. **Regular analysis**: Periodically review flow logs for security anomalies

## Getting Help

If you encounter issues:
1. Check the AWS CloudFormation events tab for detailed error messages
2. Review the [AWS VPC Flow Logs troubleshooting guide](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-troubleshooting.html)
3. Check AWS Service Health Dashboard for any service disruptions
4. Consult AWS Support or AWS forums for additional assistance
