#!/bin/bash
set -e

# VPC Flow Logs Athena Table Setup Script
# This script automates the creation of an Athena database and table for analyzing VPC Flow Logs
# Based on best practices from AWS documentation and summitroute.com blog

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DATABASE_NAME="${DATABASE_NAME:-vpc_flow_logs}"
TABLE_NAME="${TABLE_NAME:-flow_logs}"
REGION="${REGION:-us-east-1}"

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Bootstrap an Athena database and table for VPC Flow Logs analysis.

Required Environment Variables or Options:
  BUCKET_NAME or --bucket         S3 bucket name containing VPC Flow Logs
  ACCOUNT_ID or --account-id      AWS Account ID (12 digits)

Optional Environment Variables or Options:
  DATABASE_NAME or --database     Athena database name (default: vpc_flow_logs)
  TABLE_NAME or --table           Athena table name (default: flow_logs)
  REGION or --region              AWS region (default: us-east-1)
  RESULTS_BUCKET or --results     S3 bucket for Athena query results (default: same as BUCKET_NAME)
  --vpc-id VPC_ID                 Specific VPC ID to filter logs (optional)
  --partition-dates DATES         Comma-separated dates to create partitions (format: YYYY-MM-DD)
  --auto-partitions DAYS          Automatically create partitions for last N days
  --custom-format                 Use custom VPC Flow Log format (requires manual field mapping)

Examples:
  # Basic setup
  $0 --bucket my-vpc-logs --account-id 123456789012

  # With custom database/table names
  $0 --bucket my-vpc-logs --account-id 123456789012 --database security_logs --table vpc_flows

  # With automatic partition creation for last 7 days
  $0 --bucket my-vpc-logs --account-id 123456789012 --auto-partitions 7

  # Using environment variables
  export BUCKET_NAME=my-vpc-logs
  export ACCOUNT_ID=123456789012
  $0

EOF
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket)
            BUCKET_NAME="$2"
            shift 2
            ;;
        --account-id)
            ACCOUNT_ID="$2"
            shift 2
            ;;
        --database)
            DATABASE_NAME="$2"
            shift 2
            ;;
        --table)
            TABLE_NAME="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --results)
            RESULTS_BUCKET="$2"
            shift 2
            ;;
        --vpc-id)
            VPC_ID="$2"
            shift 2
            ;;
        --partition-dates)
            PARTITION_DATES="$2"
            shift 2
            ;;
        --auto-partitions)
            AUTO_PARTITION_DAYS="$2"
            shift 2
            ;;
        --custom-format)
            CUSTOM_FORMAT=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$BUCKET_NAME" ]; then
    print_error "BUCKET_NAME is required"
    usage
fi

if [ -z "$ACCOUNT_ID" ]; then
    print_error "ACCOUNT_ID is required"
    usage
fi

# Set results bucket if not specified
if [ -z "$RESULTS_BUCKET" ]; then
    RESULTS_BUCKET="$BUCKET_NAME"
fi

# Validate account ID format
if ! [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    print_error "ACCOUNT_ID must be a 12-digit number"
    exit 1
fi

print_info "Starting Athena setup for VPC Flow Logs"
print_info "Configuration:"
print_info "  Region: $REGION"
print_info "  Database: $DATABASE_NAME"
print_info "  Table: $TABLE_NAME"
print_info "  S3 Bucket: $BUCKET_NAME"
print_info "  Account ID: $ACCOUNT_ID"
print_info "  Query Results: s3://$RESULTS_BUCKET/athena-results/"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity --region "$REGION" &> /dev/null; then
    print_error "AWS credentials not configured or invalid"
    exit 1
fi

# Step 0: Configure Athena workgroup with query results location
print_info "Configuring Athena query results location..."

# Check if the primary workgroup exists and update it
WORKGROUP_EXISTS=$(aws athena list-work-groups \
    --region "$REGION" \
    --query "WorkGroups[?Name=='primary'].Name" \
    --output text 2>/dev/null)

if [ -n "$WORKGROUP_EXISTS" ]; then
    print_info "Updating primary workgroup configuration..."
    aws athena update-work-group \
        --work-group primary \
        --configuration-updates "ResultConfigurationUpdates={OutputLocation=s3://$RESULTS_BUCKET/athena-results/}" \
        --region "$REGION" 2>/dev/null || print_warn "Could not update workgroup (may not have permissions)"
else
    print_warn "Primary workgroup not found, will use output location in queries"
fi

# Ensure the S3 path exists and is accessible
print_info "Verifying S3 bucket access..."
if ! aws s3 ls "s3://$RESULTS_BUCKET/" --region "$REGION" &> /dev/null; then
    print_error "Cannot access S3 bucket: $RESULTS_BUCKET"
    print_error "Please ensure the bucket exists and you have permissions to access it"
    exit 1
fi

# Create the athena-results prefix if it doesn't exist
aws s3api put-object \
    --bucket "$RESULTS_BUCKET" \
    --key "athena-results/" \
    --region "$REGION" &> /dev/null || true

print_info "Query results will be stored at: s3://$RESULTS_BUCKET/athena-results/"

# Create temporary SQL file
TEMP_SQL=$(mktemp)
trap "rm -f $TEMP_SQL" EXIT

# Step 1: Create database
print_info "Creating Athena database '$DATABASE_NAME' (if it doesn't exist)..."
cat > "$TEMP_SQL" << EOF
CREATE DATABASE IF NOT EXISTS $DATABASE_NAME
COMMENT 'VPC Flow Logs analysis database'
LOCATION 's3://$BUCKET_NAME/athena-database/';
EOF

aws athena start-query-execution \
    --query-string "$(cat $TEMP_SQL)" \
    --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena-results/" \
    --region "$REGION" \
    --query 'QueryExecutionId' \
    --output text > /dev/null

print_info "Database created successfully"

# Step 2: Create table for VPC Flow Logs (default format)
print_info "Creating Athena table '$TABLE_NAME' for VPC Flow Logs..."

# Build S3 location path
if [ -n "$VPC_ID" ]; then
    S3_LOCATION="s3://$BUCKET_NAME/AWSLogs/$ACCOUNT_ID/vpcflowlogs/$REGION/"
else
    S3_LOCATION="s3://$BUCKET_NAME/AWSLogs/$ACCOUNT_ID/vpcflowlogs/$REGION/"
fi

# Create table DDL for default VPC Flow Log format (version 2)
cat > "$TEMP_SQL" << EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${DATABASE_NAME}.${TABLE_NAME} (
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
  \`end\` bigint,
  action string,
  log_status string
)
PARTITIONED BY (
  dt string
)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY ' '
LOCATION '$S3_LOCATION'
TBLPROPERTIES (
  "skip.header.line.count"="1",
  "projection.enabled" = "true",
  "projection.dt.type" = "date",
  "projection.dt.format" = "yyyy-MM-dd",
  "projection.dt.range" = "2020-01-01,NOW",
  "projection.dt.interval" = "1",
  "projection.dt.interval.unit" = "DAYS",
  "storage.location.template" = "$S3_LOCATION\${dt}"
);
EOF

QUERY_ID=$(aws athena start-query-execution \
    --query-string "$(cat $TEMP_SQL)" \
    --query-execution-context "Database=$DATABASE_NAME" \
    --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena-results/" \
    --region "$REGION" \
    --query 'QueryExecutionId' \
    --output text)

# Wait for table creation to complete
print_info "Waiting for table creation to complete (Query ID: $QUERY_ID)..."
sleep 3

STATUS=$(aws athena get-query-execution \
    --query-execution-id "$QUERY_ID" \
    --region "$REGION" \
    --query 'QueryExecution.Status.State' \
    --output text)

if [ "$STATUS" = "SUCCEEDED" ]; then
    print_info "Table '$TABLE_NAME' created successfully with partition projection enabled"
else
    print_error "Table creation failed. Status: $STATUS"
    aws athena get-query-execution \
        --query-execution-id "$QUERY_ID" \
        --region "$REGION" \
        --query 'QueryExecution.Status.StateChangeReason' \
        --output text
    exit 1
fi

# Step 3: Add manual partitions if requested (legacy method, not needed with projection)
if [ -n "$PARTITION_DATES" ]; then
    print_info "Adding manual partitions (Note: Using partition projection is recommended)..."
    IFS=',' read -ra DATES <<< "$PARTITION_DATES"
    for DATE in "${DATES[@]}"; do
        # Validate date format
        if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            print_warn "Invalid date format: $DATE (expected YYYY-MM-DD), skipping"
            continue
        fi

        YEAR=$(echo "$DATE" | cut -d'-' -f1)
        MONTH=$(echo "$DATE" | cut -d'-' -f2)
        DAY=$(echo "$DATE" | cut -d'-' -f3)

        cat > "$TEMP_SQL" << EOF
ALTER TABLE ${DATABASE_NAME}.${TABLE_NAME}
ADD IF NOT EXISTS PARTITION (dt='$DATE')
LOCATION '$S3_LOCATION$YEAR/$MONTH/$DAY/';
EOF

        aws athena start-query-execution \
            --query-string "$(cat $TEMP_SQL)" \
            --query-execution-context "Database=$DATABASE_NAME" \
            --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena-results/" \
            --region "$REGION" \
            --query 'QueryExecutionId' \
            --output text > /dev/null

        print_info "  Partition added: $DATE"
    done
fi

# Step 4: Auto-create partitions for last N days
if [ -n "$AUTO_PARTITION_DAYS" ]; then
    print_info "Auto-creating partitions for last $AUTO_PARTITION_DAYS days..."
    for i in $(seq 0 $((AUTO_PARTITION_DAYS - 1))); do
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            DATE=$(date -v-${i}d +%Y-%m-%d)
        else
            # Linux
            DATE=$(date -d "$i days ago" +%Y-%m-%d)
        fi

        YEAR=$(echo "$DATE" | cut -d'-' -f1)
        MONTH=$(echo "$DATE" | cut -d'-' -f2)
        DAY=$(echo "$DATE" | cut -d'-' -f3)

        cat > "$TEMP_SQL" << EOF
ALTER TABLE ${DATABASE_NAME}.${TABLE_NAME}
ADD IF NOT EXISTS PARTITION (dt='$DATE')
LOCATION '$S3_LOCATION$YEAR/$MONTH/$DAY/';
EOF

        aws athena start-query-execution \
            --query-string "$(cat $TEMP_SQL)" \
            --query-execution-context "Database=$DATABASE_NAME" \
            --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena-results/" \
            --region "$REGION" \
            --query 'QueryExecutionId' \
            --output text > /dev/null

        print_info "  Partition added: $DATE"
    done
fi

# Step 5: Run a test query to verify setup
print_info "Running test query to verify setup..."
cat > "$TEMP_SQL" << EOF
SELECT COUNT(*) as record_count
FROM ${DATABASE_NAME}.${TABLE_NAME}
LIMIT 10;
EOF

TEST_QUERY_ID=$(aws athena start-query-execution \
    --query-string "$(cat $TEMP_SQL)" \
    --query-execution-context "Database=$DATABASE_NAME" \
    --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena-results/" \
    --region "$REGION" \
    --query 'QueryExecutionId' \
    --output text)

sleep 5

TEST_STATUS=$(aws athena get-query-execution \
    --query-execution-id "$TEST_QUERY_ID" \
    --region "$REGION" \
    --query 'QueryExecution.Status.State' \
    --output text)

if [ "$TEST_STATUS" = "SUCCEEDED" ]; then
    print_info "Test query succeeded - Athena table is ready!"
else
    print_warn "Test query status: $TEST_STATUS (This is normal if no data exists yet)"
fi

# Print summary and next steps
print_info ""
print_info "============================================="
print_info "Athena Setup Complete!"
print_info "============================================="
print_info ""
print_info "Configuration:"
print_info "  Database: $DATABASE_NAME"
print_info "  Table: ${DATABASE_NAME}.${TABLE_NAME}"
print_info "  Region: $REGION"
print_info "  Query Results: s3://$RESULTS_BUCKET/athena-results/"
print_info ""
print_info "Next Steps:"
print_info "1. Open Athena Console: https://console.aws.amazon.com/athena/home?region=$REGION"
print_info "2. Select database: $DATABASE_NAME"
print_info "3. Run queries against table: $TABLE_NAME"
print_info "4. Query results will automatically be saved to s3://$RESULTS_BUCKET/athena-results/"
print_info ""
print_info "Example Query:"
print_info "  SELECT * FROM ${DATABASE_NAME}.${TABLE_NAME} LIMIT 100;"
print_info ""
print_info "Query Cheatsheets:"
print_info "  - CloudWatch Queries: CLOUDWATCH_QUERIES.md"
print_info "  - Athena Incident Response: ATHENA_INCIDENT_RESPONSE.md"
print_info ""
print_info "Note: It may take 5-15 minutes for flow logs to appear after VPC Flow Logs are enabled."
print_info ""
