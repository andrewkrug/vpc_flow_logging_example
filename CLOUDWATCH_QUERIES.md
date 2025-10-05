# CloudWatch Logs Insights Query Cheatsheet

This cheatsheet provides example queries for analyzing VPC Flow Logs in CloudWatch Logs Insights. These queries help you troubleshoot network issues, identify security threats, and understand traffic patterns.

## Getting Started

1. Open [CloudWatch Console](https://console.aws.amazon.com/cloudwatch/)
2. Navigate to **Logs** → **Logs Insights**
3. Select your VPC Flow Logs log group
4. Choose a time range
5. Paste a query and click **Run query**

## Understanding VPC Flow Log Fields

VPC Flow Logs use a space-delimited format with these default fields:

| Field | Description | Example |
|-------|-------------|---------|
| `@timestamp` | CloudWatch timestamp | `2024-01-15T10:30:00.000Z` |
| `version` | Flow log version | `2` |
| `account_id` | AWS account ID | `123456789010` |
| `interface_id` | Network interface ID | `eni-1235b8ca123456789` |
| `srcaddr` | Source IP address | `172.31.16.139` |
| `dstaddr` | Destination IP address | `172.31.16.21` |
| `srcport` | Source port | `20641` |
| `dstport` | Destination port | `22` |
| `protocol` | IANA protocol number | `6` (TCP) |
| `packets` | Number of packets | `20` |
| `bytes` | Number of bytes | `4249` |
| `start` | Start time (Unix seconds) | `1418530010` |
| `end` | End time (Unix seconds) | `1418530070` |
| `action` | `ACCEPT` or `REJECT` | `ACCEPT` |
| `log_status` | Logging status | `OK` |

**Protocol Numbers**: 1 = ICMP, 6 = TCP, 17 = UDP

## Basic Queries

### View Recent Flow Logs

```
fields @timestamp, srcaddr, dstaddr, srcport, dstport, action
| sort @timestamp desc
| limit 100
```

### View All Fields from Recent Logs

```
fields @timestamp, interface_id, srcaddr, dstaddr, srcport, dstport, protocol, bytes, packets, action
| sort @timestamp desc
| limit 50
```

### Count Total Flow Records

```
stats count() as total_flows
```

## Traffic Analysis

### Top Talkers by Bytes Transferred

Find which connections are transferring the most data:

```
stats sum(bytes) as total_bytes by srcaddr, dstaddr
| sort total_bytes desc
| limit 20
```

### Top Talkers by Packet Count

```
stats sum(packets) as total_packets by srcaddr, dstaddr
| sort total_packets desc
| limit 20
```

### Traffic Volume Over Time (5-minute intervals)

```
stats sum(bytes) as total_bytes by bin(5m)
| sort bin(5m) asc
```

### Traffic by Source IP Address

```
stats sum(bytes) as total_bytes, sum(packets) as total_packets, count() as flow_count by srcaddr
| sort total_bytes desc
| limit 20
```

### Traffic by Destination IP Address

```
stats sum(bytes) as total_bytes, sum(packets) as total_packets, count() as flow_count by dstaddr
| sort total_bytes desc
| limit 20
```

### Traffic by Protocol

```
stats sum(bytes) as total_bytes, count() as flow_count by protocol
| sort total_bytes desc
```

### Busiest Network Interfaces

```
stats sum(bytes) as total_bytes, sum(packets) as total_packets by interface_id
| sort total_bytes desc
| limit 10
```

## Security Analysis

### Find Rejected Traffic (Blocked by Security Groups/NACLs)

Useful for identifying potentially malicious traffic or misconfigured security rules:

```
fields @timestamp, srcaddr, dstaddr, srcport, dstport, protocol, action
| filter action = "REJECT"
| sort @timestamp desc
| limit 100
```

### Top Sources of Rejected Traffic

Identify IP addresses generating the most blocked connection attempts:

```
fields srcaddr, dstaddr, dstport
| filter action = "REJECT"
| stats count() as reject_count by srcaddr, dstaddr, dstport
| sort reject_count desc
| limit 50
```

### Rejected Traffic by Destination Port

Find which ports are being targeted by blocked traffic:

```
filter action = "REJECT"
| stats count() as reject_count by dstport
| sort reject_count desc
| limit 20
```

### SSH Connection Attempts

Monitor SSH access to your instances:

```
fields @timestamp, srcaddr, dstaddr, action
| filter dstport = 22 and protocol = 6
| sort @timestamp desc
```

### Failed SSH Connection Attempts

```
fields @timestamp, srcaddr, dstaddr
| filter dstport = 22 and protocol = 6 and action = "REJECT"
| stats count() as failed_attempts by srcaddr
| sort failed_attempts desc
```

### RDP Connection Attempts

Monitor RDP access (Windows Remote Desktop):

```
fields @timestamp, srcaddr, dstaddr, action
| filter dstport = 3389 and protocol = 6
| sort @timestamp desc
```

### Database Connection Attempts

Monitor access to common database ports:

```
# MySQL/MariaDB (3306), PostgreSQL (5432), MSSQL (1433)
fields @timestamp, srcaddr, dstaddr, dstport, action
| filter (dstport = 3306 or dstport = 5432 or dstport = 1433) and protocol = 6
| sort @timestamp desc
```

### Potential Port Scanning Activity

Identify sources connecting to many different ports (possible reconnaissance):

```
fields srcaddr, dstaddr, dstport
| stats count_distinct(dstport) as unique_ports by srcaddr, dstaddr
| filter unique_ports > 20
| sort unique_ports desc
```

### External IP Addresses Accessing Your VPC

Find traffic originating from outside your VPC:

```
fields @timestamp, srcaddr, dstaddr, dstport, action
| filter not srcaddr like /^10\./
       and not srcaddr like /^172\.(1[6-9]|2[0-9]|3[0-1])\./
       and not srcaddr like /^192\.168\./
| stats count() as connection_count by srcaddr
| sort connection_count desc
| limit 50
```

### Traffic to External IP Addresses

Monitor outbound traffic to the internet:

```
fields @timestamp, srcaddr, dstaddr, dstport, bytes
| filter not dstaddr like /^10\./
       and not dstaddr like /^172\.(1[6-9]|2[0-9]|3[0-1])\./
       and not dstaddr like /^192\.168\./
| stats sum(bytes) as total_bytes, count() as connection_count by dstaddr
| sort total_bytes desc
| limit 50
```

## Application-Specific Queries

### HTTP/HTTPS Traffic

```
fields @timestamp, srcaddr, dstaddr, dstport, bytes, action
| filter (dstport = 80 or dstport = 443) and protocol = 6
| stats sum(bytes) as total_bytes by dstaddr, dstport
| sort total_bytes desc
```

### DNS Traffic

```
fields @timestamp, srcaddr, dstaddr, action
| filter dstport = 53 and protocol = 17
| stats count() as query_count by srcaddr
| sort query_count desc
```

### SMTP Traffic (Email)

```
fields @timestamp, srcaddr, dstaddr, dstport, action
| filter (dstport = 25 or dstport = 587 or dstport = 465) and protocol = 6
| sort @timestamp desc
```

### FTP Traffic

```
fields @timestamp, srcaddr, dstaddr, action
| filter (dstport = 20 or dstport = 21) and protocol = 6
| sort @timestamp desc
```

## Advanced Queries

### Connection Duration Analysis

Calculate average connection duration in seconds:

```
fields @timestamp, srcaddr, dstaddr, dstport, (end - start) as duration
| stats avg(duration) as avg_duration_sec, max(duration) as max_duration_sec by dstport
| sort avg_duration_sec desc
```

### Long-Running Connections

Find connections lasting longer than 5 minutes (300 seconds):

```
fields @timestamp, srcaddr, dstaddr, dstport, (end - start) as duration
| filter (end - start) > 300
| sort duration desc
| limit 50
```

### Small Packet Analysis (Potential Keep-Alives or Probes)

```
fields @timestamp, srcaddr, dstaddr, dstport, bytes, packets
| filter bytes < 100
| stats count() as small_packet_count by srcaddr, dstaddr, dstport
| sort small_packet_count desc
| limit 50
```

### Large Data Transfers

Identify flows transferring more than 10 MB:

```
fields @timestamp, srcaddr, dstaddr, dstport, bytes, action
| filter bytes > 10485760
| sort bytes desc
| limit 50
```

### Traffic from Specific IP Address

```
fields @timestamp, srcaddr, dstaddr, srcport, dstport, protocol, bytes, action
| filter srcaddr = "10.0.1.100"
| sort @timestamp desc
```

### Traffic to Specific IP Address

```
fields @timestamp, srcaddr, dstaddr, srcport, dstport, protocol, bytes, action
| filter dstaddr = "10.0.1.200"
| sort @timestamp desc
```

### Traffic Between Two Specific IPs

```
fields @timestamp, srcaddr, dstaddr, srcport, dstport, bytes, action
| filter (srcaddr = "10.0.1.100" and dstaddr = "10.0.1.200")
       or (srcaddr = "10.0.1.200" and dstaddr = "10.0.1.100")
| sort @timestamp desc
```

### Connections Per Minute

```
stats count() as connections by bin(1m)
| sort bin(1m) asc
```

### Unique Source IPs Per Destination Port

```
stats count_distinct(srcaddr) as unique_sources by dstport
| sort unique_sources desc
| limit 20
```

### ICMP Traffic Analysis

```
fields @timestamp, srcaddr, dstaddr, bytes, action
| filter protocol = 1
| stats count() as icmp_count, sum(bytes) as total_bytes by srcaddr, dstaddr
| sort icmp_count desc
```

### UDP Traffic Analysis

```
fields @timestamp, srcaddr, dstaddr, dstport, bytes, action
| filter protocol = 17
| stats sum(bytes) as total_bytes, count() as flow_count by dstport
| sort total_bytes desc
| limit 20
```

## Troubleshooting Queries

### Find Connection Timeouts (Short Duration, Few Packets)

Possible indication of connection issues:

```
fields @timestamp, srcaddr, dstaddr, dstport, packets, (end - start) as duration
| filter packets < 5 and (end - start) < 10
| stats count() as timeout_count by srcaddr, dstaddr, dstport
| sort timeout_count desc
```

### Asymmetric Routing Detection

Find traffic accepted in one direction but rejected in the other:

```
fields @timestamp, srcaddr, dstaddr, dstport, action
| filter action = "REJECT"
| stats count() as reject_count by srcaddr, dstaddr, dstport
| sort reject_count desc
```

### Find All Traffic to/from a Specific Network Interface

```
fields @timestamp, srcaddr, dstaddr, srcport, dstport, bytes, action
| filter interface_id = "eni-1234567890abcdef0"
| sort @timestamp desc
```

### Identify Flows with Log Status Issues

```
fields @timestamp, srcaddr, dstaddr, dstport, log_status
| filter log_status != "OK"
| stats count() as error_count by log_status
```

## Performance Optimization Tips

1. **Specify time ranges**: Narrow time ranges improve query performance
2. **Use filters early**: Place `filter` commands before `stats` when possible
3. **Limit results**: Use `limit` to reduce data processing
4. **Use specific fields**: Only select fields you need with `fields` command
5. **Aggregate wisely**: Use `stats` to summarize large datasets

## Creating CloudWatch Alarms

You can create alarms based on metric filters. Example metric filter patterns:

### Alert on High Rejected Traffic

Metric filter pattern:
```
[version, account_id, interface_id, srcaddr, dstaddr, srcport, dstport, protocol, packets, bytes, start, end, action=REJECT, log_status]
```

### Alert on SSH Brute Force Attempts

Metric filter pattern:
```
[version, account_id, interface_id, srcaddr, dstaddr, srcport, dstport=22, protocol=6, packets, bytes, start, end, action=REJECT, log_status]
```

## Additional Resources

- [CloudWatch Logs Insights Query Syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html)
- [VPC Flow Logs Records](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html#flow-logs-fields)
- [CloudWatch Logs Insights Sample Queries](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax-examples.html)
- [IANA Protocol Numbers](https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml)

## Common Protocol Numbers Reference

| Protocol | Number | Description |
|----------|--------|-------------|
| ICMP | 1 | Internet Control Message Protocol |
| IGMP | 2 | Internet Group Management Protocol |
| TCP | 6 | Transmission Control Protocol |
| UDP | 17 | User Datagram Protocol |
| GRE | 47 | Generic Routing Encapsulation |
| ESP | 50 | Encapsulating Security Payload |
| AH | 51 | Authentication Header |
| ICMPv6 | 58 | ICMP for IPv6 |

## Common Port Numbers Reference

| Port | Protocol | Service |
|------|----------|---------|
| 20-21 | TCP | FTP |
| 22 | TCP | SSH |
| 23 | TCP | Telnet |
| 25 | TCP | SMTP |
| 53 | TCP/UDP | DNS |
| 80 | TCP | HTTP |
| 110 | TCP | POP3 |
| 143 | TCP | IMAP |
| 443 | TCP | HTTPS |
| 465 | TCP | SMTPS |
| 587 | TCP | SMTP (submission) |
| 993 | TCP | IMAPS |
| 995 | TCP | POP3S |
| 1433 | TCP | MS SQL Server |
| 3306 | TCP | MySQL/MariaDB |
| 3389 | TCP | RDP (Remote Desktop) |
| 5432 | TCP | PostgreSQL |
| 6379 | TCP | Redis |
| 8080 | TCP | HTTP Alternate |
| 27017 | TCP | MongoDB |
