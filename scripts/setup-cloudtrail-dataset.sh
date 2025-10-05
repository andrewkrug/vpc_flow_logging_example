#!/bin/bash
set -e

# CloudTrail Public Dataset Setup Script
# Downloads and sets up the public CloudTrail dataset from flaws.cloud for analysis
# Based on: https://summitroute.com/blog/2020/10/09/public_dataset_of_cloudtrail_logs_from_flaws_cloud/

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DATABASE_NAME="${DATABASE_NAME:-cloudtrail_demo}"
TABLE_NAME="${TABLE_NAME:-cloudtrail_logs}"
REGION="${REGION:-us-east-1}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-./data/cloudtrail}"
DATASET_URL="https://summitroute.com/downloads/flaws_cloudtrail_logs.tar"

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

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Download and setup the public CloudTrail dataset from flaws.cloud for Athena analysis.

Required Environment Variables or Options:
  BUCKET_NAME or --bucket         S3 bucket name to upload CloudTrail logs

Optional Environment Variables or Options:
  DATABASE_NAME or --database     Athena database name (default: cloudtrail_demo)
  TABLE_NAME or --table           Athena table name (default: cloudtrail_logs)
  REGION or --region              AWS region (default: us-east-1)
  RESULTS_BUCKET or --results     S3 bucket for Athena query results (default: same as BUCKET_NAME)
  DOWNLOAD_DIR or --download-dir  Local directory for downloads (default: ./data/cloudtrail)
  --skip-download                 Skip download if data already exists locally
  --skip-upload                   Skip upload to S3 (use if already uploaded)
  --cleanup                       Delete local files after upload

Examples:
  # Basic setup
  $0 --bucket my-security-analysis-bucket

  # Custom database and skip cleanup
  $0 --bucket my-bucket --database security_logs --table ct_logs

  # Skip download if already downloaded
  $0 --bucket my-bucket --skip-download

  # Using environment variables
  export BUCKET_NAME=my-bucket
  $0

Dataset Information:
  Source: https://summitroute.com/blog/2020/10/09/public_dataset_of_cloudtrail_logs_from_flaws_cloud/
  Size: ~200MB compressed, ~2GB uncompressed
  Account: flaws.cloud (811596193553)
  Date Range: June 2017
  Use Case: Training, testing, and learning CloudTrail analysis

EOF
    exit 1
}

# Parse command line arguments
SKIP_DOWNLOAD=false
SKIP_UPLOAD=false
CLEANUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket)
            BUCKET_NAME="$2"
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
        --download-dir)
            DOWNLOAD_DIR="$2"
            shift 2
            ;;
        --skip-download)
            SKIP_DOWNLOAD=true
            shift
            ;;
        --skip-upload)
            SKIP_UPLOAD=true
            shift
            ;;
        --cleanup)
            CLEANUP=true
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

# Set results bucket if not specified
if [ -z "$RESULTS_BUCKET" ]; then
    RESULTS_BUCKET="$BUCKET_NAME"
fi

print_info "CloudTrail Public Dataset Setup"
print_info "Dataset: flaws.cloud CloudTrail logs"
print_info "Configuration:"
print_info "  S3 Bucket: $BUCKET_NAME"
print_info "  Region: $REGION"
print_info "  Database: $DATABASE_NAME"
print_info "  Table: $TABLE_NAME"
print_info "  Download Directory: $DOWNLOAD_DIR"
print_info "  Query Results: s3://$RESULTS_BUCKET/athena-results/"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check if curl or wget is available
if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    print_error "Neither curl nor wget is installed. Please install one of them."
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity --region "$REGION" &> /dev/null; then
    print_error "AWS credentials not configured or invalid"
    exit 1
fi

# Step 1: Download the dataset
if [ "$SKIP_DOWNLOAD" = false ]; then
    print_step "Step 1: Downloading CloudTrail dataset from Summit Route"
    print_info "Dataset URL: $DATASET_URL"
    print_info "Size: ~200MB (this may take a few minutes)"

    # Create download directory
    mkdir -p "$DOWNLOAD_DIR"

    # Download the tar file
    TARFILE="$DOWNLOAD_DIR/flaws_cloudtrail_logs.tar"

    if [ -f "$TARFILE" ]; then
        print_warn "Tar file already exists at $TARFILE"
        read -p "Do you want to re-download? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm "$TARFILE"
        else
            print_info "Using existing tar file"
        fi
    fi

    if [ ! -f "$TARFILE" ]; then
        if command -v curl &> /dev/null; then
            curl -L -o "$TARFILE" "$DATASET_URL" --progress-bar
        else
            wget -O "$TARFILE" "$DATASET_URL" --show-progress
        fi
        print_info "Download complete"
    fi

    # Step 2: Extract the tar file
    print_step "Step 2: Extracting CloudTrail logs"
    cd "$DOWNLOAD_DIR"
    tar -xf flaws_cloudtrail_logs.tar
    cd - > /dev/null

    print_info "Extraction complete"

    # Show what we have
    LOG_COUNT=$(find "$DOWNLOAD_DIR/flaws.cloud" -name "*.json.gz" 2>/dev/null | wc -l | tr -d ' ')
    print_info "Found $LOG_COUNT CloudTrail log files"
else
    print_step "Step 1: Skipping download (using existing files)"

    # Verify files exist
    if [ ! -d "$DOWNLOAD_DIR/flaws.cloud" ]; then
        print_error "CloudTrail logs not found at $DOWNLOAD_DIR/flaws.cloud"
        print_error "Run without --skip-download first"
        exit 1
    fi

    LOG_COUNT=$(find "$DOWNLOAD_DIR/flaws.cloud" -name "*.json.gz" 2>/dev/null | wc -l | tr -d ' ')
    print_info "Found $LOG_COUNT CloudTrail log files"
fi

# Step 3: Upload to S3
if [ "$SKIP_UPLOAD" = false ]; then
    print_step "Step 3: Uploading CloudTrail logs to S3"
    print_info "Destination: s3://$BUCKET_NAME/cloudtrail-demo/flaws.cloud/"

    # Verify bucket exists
    if ! aws s3 ls "s3://$BUCKET_NAME/" --region "$REGION" &> /dev/null; then
        print_error "S3 bucket '$BUCKET_NAME' does not exist or is not accessible"
        exit 1
    fi

    # Upload the CloudTrail logs maintaining directory structure
    aws s3 sync "$DOWNLOAD_DIR/flaws.cloud" "s3://$BUCKET_NAME/cloudtrail-demo/flaws.cloud/" \
        --region "$REGION" \
        --exclude "*" \
        --include "*.json.gz"

    print_info "Upload complete"
else
    print_step "Step 3: Skipping upload to S3"
fi

# Step 4: Create Athena database
print_step "Step 4: Setting up Athena database and table"

# Configure Athena workgroup
print_info "Configuring Athena query results location..."
aws athena update-work-group \
    --work-group primary \
    --configuration-updates "ResultConfigurationUpdates={OutputLocation=s3://$RESULTS_BUCKET/athena-results/}" \
    --region "$REGION" 2>/dev/null || print_warn "Could not update workgroup (may not have permissions)"

# Create the athena-results prefix if it doesn't exist
aws s3api put-object \
    --bucket "$RESULTS_BUCKET" \
    --key "athena-results/" \
    --region "$REGION" &> /dev/null || true

# Create temporary SQL file
TEMP_SQL=$(mktemp)
trap "rm -f $TEMP_SQL" EXIT

# Create database
print_info "Creating Athena database '$DATABASE_NAME'..."
cat > "$TEMP_SQL" << EOF
CREATE DATABASE IF NOT EXISTS $DATABASE_NAME
COMMENT 'CloudTrail demo dataset from flaws.cloud'
LOCATION 's3://$BUCKET_NAME/athena-database/';
EOF

aws athena start-query-execution \
    --query-string "$(cat $TEMP_SQL)" \
    --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena-results/" \
    --region "$REGION" \
    --query 'QueryExecutionId' \
    --output text > /dev/null

print_info "Database created"

# Step 5: Create CloudTrail table
print_step "Step 5: Creating CloudTrail table with partitions"

# Create table for CloudTrail logs
# Schema from: https://docs.aws.amazon.com/athena/latest/ug/cloudtrail-logs.html
cat > "$TEMP_SQL" << 'EOF_SQL'
CREATE EXTERNAL TABLE IF NOT EXISTS cloudtrail_logs (
  eventversion STRING,
  useridentity STRUCT<
    type:STRING,
    principalid:STRING,
    arn:STRING,
    accountid:STRING,
    invokedby:STRING,
    accesskeyid:STRING,
    userName:STRING,
    sessioncontext:STRUCT<
      attributes:STRUCT<
        mfaauthenticated:STRING,
        creationdate:STRING>,
      sessionissuer:STRUCT<
        type:STRING,
        principalId:STRING,
        arn:STRING,
        accountId:STRING,
        userName:STRING>>>,
  eventtime STRING,
  eventsource STRING,
  eventname STRING,
  awsregion STRING,
  sourceipaddress STRING,
  useragent STRING,
  errorcode STRING,
  errormessage STRING,
  requestparameters STRING,
  responseelements STRING,
  additionaleventdata STRING,
  requestid STRING,
  eventid STRING,
  resources ARRAY<STRUCT<
    ARN:STRING,
    accountId:STRING,
    type:STRING>>,
  eventtype STRING,
  apiversion STRING,
  readonly STRING,
  recipientaccountid STRING,
  serviceeventdetails STRING,
  sharedeventid STRING,
  vpcendpointid STRING
)
PARTITIONED BY (
  account STRING,
  region STRING,
  year STRING,
  month STRING,
  day STRING
)
ROW FORMAT SERDE 'com.amazon.emr.hive.serde.CloudTrailSerde'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION 's3://BUCKET_PLACEHOLDER/cloudtrail-demo/';
EOF_SQL

# Replace placeholder with actual bucket name
sed -i.bak "s/cloudtrail_logs/${DATABASE_NAME}.${TABLE_NAME}/g" "$TEMP_SQL"
sed -i.bak "s|BUCKET_PLACEHOLDER|$BUCKET_NAME|g" "$TEMP_SQL"
rm -f "${TEMP_SQL}.bak"

print_info "Creating table $TABLE_NAME..."

QUERY_ID=$(aws athena start-query-execution \
    --query-string "$(cat $TEMP_SQL)" \
    --query-execution-context "Database=$DATABASE_NAME" \
    --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena-results/" \
    --region "$REGION" \
    --query 'QueryExecutionId' \
    --output text)

# Wait for table creation
sleep 3
STATUS=$(aws athena get-query-execution \
    --query-execution-id "$QUERY_ID" \
    --region "$REGION" \
    --query 'QueryExecution.Status.State' \
    --output text)

if [ "$STATUS" = "SUCCEEDED" ]; then
    print_info "Table created successfully"
else
    print_error "Table creation failed. Status: $STATUS"
    exit 1
fi

# Step 6: Add partitions
print_step "Step 6: Adding partitions for CloudTrail data"

# The flaws.cloud dataset has logs from June 2017 in us-west-2
# We need to find what partitions exist in S3
print_info "Discovering partitions from S3..."

# List unique dates from S3
PARTITIONS=$(aws s3 ls "s3://$BUCKET_NAME/cloudtrail-demo/flaws.cloud/AWSLogs/811596193553/CloudTrail/us-west-2/2017/" \
    --recursive \
    --region "$REGION" \
    | grep -o '2017/[0-9][0-9]/[0-9][0-9]/' \
    | sort -u)

PARTITION_COUNT=$(echo "$PARTITIONS" | wc -l | tr -d ' ')
print_info "Found $PARTITION_COUNT unique date partitions"

# Add each partition
for PARTITION_PATH in $PARTITIONS; do
    YEAR=$(echo "$PARTITION_PATH" | cut -d'/' -f1)
    MONTH=$(echo "$PARTITION_PATH" | cut -d'/' -f2)
    DAY=$(echo "$PARTITION_PATH" | cut -d'/' -f3)

    cat > "$TEMP_SQL" << EOF
ALTER TABLE ${DATABASE_NAME}.${TABLE_NAME}
ADD IF NOT EXISTS PARTITION (
  account='811596193553',
  region='us-west-2',
  year='$YEAR',
  month='$MONTH',
  day='$DAY'
)
LOCATION 's3://$BUCKET_NAME/cloudtrail-demo/flaws.cloud/AWSLogs/811596193553/CloudTrail/us-west-2/$YEAR/$MONTH/$DAY/';
EOF

    aws athena start-query-execution \
        --query-string "$(cat $TEMP_SQL)" \
        --query-execution-context "Database=$DATABASE_NAME" \
        --result-configuration "OutputLocation=s3://$RESULTS_BUCKET/athena-results/" \
        --region "$REGION" \
        --query 'QueryExecutionId' \
        --output text > /dev/null

    print_info "  Added partition: $YEAR/$MONTH/$DAY"
done

# Step 7: Run test query
print_step "Step 7: Running test query"
cat > "$TEMP_SQL" << EOF
SELECT
  eventname,
  COUNT(*) AS event_count
FROM ${DATABASE_NAME}.${TABLE_NAME}
GROUP BY eventname
ORDER BY event_count DESC
LIMIT 10;
EOF

print_info "Querying top 10 CloudTrail events..."
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
    print_info "Test query succeeded!"

    # Get query results
    aws athena get-query-results \
        --query-execution-id "$TEST_QUERY_ID" \
        --region "$REGION" \
        --query 'ResultSet.Rows[*].Data[*].VarCharValue' \
        --output table 2>/dev/null || true
else
    print_warn "Test query status: $TEST_STATUS"
fi

# Step 8: Cleanup if requested
if [ "$CLEANUP" = true ]; then
    print_step "Step 8: Cleaning up local files"
    rm -rf "$DOWNLOAD_DIR"
    print_info "Local files removed"
fi

# Print summary
print_info ""
print_info "============================================="
print_info "CloudTrail Dataset Setup Complete!"
print_info "============================================="
print_info ""
print_info "Dataset Information:"
print_info "  Source: flaws.cloud (Scott Piper's security training site)"
print_info "  AWS Account: 811596193553"
print_info "  Region: us-west-2"
print_info "  Date Range: June 2017"
print_info "  Records: ~10,000+ CloudTrail events"
print_info ""
print_info "Athena Configuration:"
print_info "  Database: $DATABASE_NAME"
print_info "  Table: ${DATABASE_NAME}.${TABLE_NAME}"
print_info "  S3 Location: s3://$BUCKET_NAME/cloudtrail-demo/"
print_info "  Query Results: s3://$RESULTS_BUCKET/athena-results/"
print_info ""
print_info "Next Steps:"
print_info "1. Open Athena Console: https://console.aws.amazon.com/athena/home?region=$REGION"
print_info "2. Select database: $DATABASE_NAME"
print_info "3. Run queries against table: $TABLE_NAME"
print_info ""
print_info "Example Queries:"
print_info ""
print_info "# Find all events by a specific user"
print_info "SELECT eventname, sourceipaddress, eventtime"
print_info "FROM ${DATABASE_NAME}.${TABLE_NAME}"
print_info "WHERE useridentity.arn = 'arn:aws:iam::811596193553:user/Level6'"
print_info "ORDER BY eventtime;"
print_info ""
print_info "# Find all failed API calls"
print_info "SELECT eventname, errorcode, errormessage, COUNT(*) as count"
print_info "FROM ${DATABASE_NAME}.${TABLE_NAME}"
print_info "WHERE errorcode IS NOT NULL"
print_info "GROUP BY eventname, errorcode, errormessage"
print_info "ORDER BY count DESC;"
print_info ""
print_info "# Find IAM changes"
print_info "SELECT eventtime, eventname, useridentity.arn, sourceipaddress"
print_info "FROM ${DATABASE_NAME}.${TABLE_NAME}"
print_info "WHERE eventsource = 'iam.amazonaws.com'"
print_info "ORDER BY eventtime;"
print_info ""
print_info "Blog Post: https://summitroute.com/blog/2020/10/09/public_dataset_of_cloudtrail_logs_from_flaws_cloud/"
print_info ""
