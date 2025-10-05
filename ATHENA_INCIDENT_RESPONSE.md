# Athena Incident Response & Investigation Query Cheatsheet

This cheatsheet provides SQL queries for analyzing VPC Flow Logs in Amazon Athena during security incidents and investigations. These queries help you quickly identify threats, trace attacker activities, and understand the scope of security events.

## Prerequisites

Before using these queries, ensure you have:

1. VPC Flow Logs flowing to S3
2. Athena table created (see main README.md for setup instructions)
3. Partitions loaded for the date ranges you want to investigate
4. Query results bucket configured in Athena

## Table of Contents

- [Initial Incident Assessment](#initial-incident-assessment)
- [Attacker Reconnaissance](#attacker-reconnaissance)
- [Lateral Movement Detection](#lateral-movement-detection)
- [Data Exfiltration](#data-exfiltration)
- [Compromised Host Investigation](#compromised-host-investigation)
- [Timeline Analysis](#timeline-analysis)
- [Network-Based Attacks](#network-based-attacks)
- [Persistence & C2 Communication](#persistence--c2-communication)
- [Baseline Deviations](#baseline-deviations)
- [Multi-Stage Attack Chains](#multi-stage-attack-chains)

---

## Initial Incident Assessment

### Quick Overview of Traffic for Incident Timeframe

Replace date and time ranges with your incident window:

```sql
SELECT
  srcaddr,
  dstaddr,
  dstport,
  protocol,
  action,
  COUNT(*) as connection_count,
  SUM(bytes) as total_bytes,
  SUM(packets) as total_packets
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND start >= UNIX_TIMESTAMP(TIMESTAMP '2024-01-15 14:00:00')
  AND end <= UNIX_TIMESTAMP(TIMESTAMP '2024-01-15 18:00:00')
GROUP BY srcaddr, dstaddr, dstport, protocol, action
ORDER BY total_bytes DESC
LIMIT 100;
```

### All Activity Involving Suspicious IP Address

```sql
SELECT
  FROM_UNIXTIME(start) as start_time,
  FROM_UNIXTIME(end) as end_time,
  srcaddr,
  dstaddr,
  srcport,
  dstport,
  protocol,
  action,
  bytes,
  packets,
  interface_id
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND (srcaddr = '203.0.113.10' OR dstaddr = '203.0.113.10')
ORDER BY start;
```

### Find All Internal IPs Communicating with Known Malicious IP

```sql
SELECT DISTINCT
  CASE
    WHEN srcaddr = '203.0.113.10' THEN dstaddr
    WHEN dstaddr = '203.0.113.10' THEN srcaddr
  END as internal_ip,
  COUNT(*) as connection_count,
  SUM(bytes) as total_bytes,
  MIN(FROM_UNIXTIME(start)) as first_seen,
  MAX(FROM_UNIXTIME(end)) as last_seen
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND (srcaddr = '203.0.113.10' OR dstaddr = '203.0.113.10')
GROUP BY
  CASE
    WHEN srcaddr = '203.0.113.10' THEN dstaddr
    WHEN dstaddr = '203.0.113.10' THEN srcaddr
  END
ORDER BY connection_count DESC;
```

### Rejected vs Accepted Traffic Ratio (Detect Security Control Effectiveness)

```sql
SELECT
  srcaddr,
  dstaddr,
  dstport,
  SUM(CASE WHEN action = 'ACCEPT' THEN 1 ELSE 0 END) as accepted,
  SUM(CASE WHEN action = 'REJECT' THEN 1 ELSE 0 END) as rejected,
  ROUND(
    CAST(SUM(CASE WHEN action = 'REJECT' THEN 1 ELSE 0 END) AS DOUBLE) /
    CAST(COUNT(*) AS DOUBLE) * 100,
    2
  ) as reject_percentage
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
GROUP BY srcaddr, dstaddr, dstport
HAVING COUNT(*) > 10
ORDER BY rejected DESC
LIMIT 50;
```

---

## Attacker Reconnaissance

### Port Scanning Detection

Identify sources scanning multiple ports on the same destination:

```sql
SELECT
  srcaddr,
  dstaddr,
  COUNT(DISTINCT dstport) as unique_ports_scanned,
  COUNT(*) as total_attempts,
  SUM(CASE WHEN action = 'REJECT' THEN 1 ELSE 0 END) as rejected_attempts,
  MIN(FROM_UNIXTIME(start)) as scan_start,
  MAX(FROM_UNIXTIME(end)) as scan_end,
  ARRAY_AGG(DISTINCT dstport ORDER BY dstport) as ports_targeted
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND protocol = 6  -- TCP
GROUP BY srcaddr, dstaddr
HAVING COUNT(DISTINCT dstport) > 20  -- Adjust threshold as needed
ORDER BY unique_ports_scanned DESC
LIMIT 50;
```

### Network Sweep Detection

Identify sources scanning multiple hosts (horizontal scanning):

```sql
SELECT
  srcaddr,
  dstport,
  COUNT(DISTINCT dstaddr) as unique_hosts_scanned,
  COUNT(*) as total_attempts,
  SUM(CASE WHEN action = 'REJECT' THEN 1 ELSE 0 END) as rejected_attempts,
  MIN(FROM_UNIXTIME(start)) as sweep_start,
  MAX(FROM_UNIXTIME(end)) as sweep_end
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND protocol = 6  -- TCP
GROUP BY srcaddr, dstport
HAVING COUNT(DISTINCT dstaddr) > 10  -- Adjust threshold
ORDER BY unique_hosts_scanned DESC
LIMIT 50;
```

### Rapid Connection Attempts (Possible Automated Scanning)

```sql
SELECT
  srcaddr,
  dstaddr,
  dstport,
  COUNT(*) as attempts,
  (MAX(end) - MIN(start)) as duration_seconds,
  ROUND(
    CAST(COUNT(*) AS DOUBLE) / CAST((MAX(end) - MIN(start)) AS DOUBLE),
    2
  ) as attempts_per_second
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
GROUP BY srcaddr, dstaddr, dstport
HAVING COUNT(*) > 50 AND (MAX(end) - MIN(start)) > 0
ORDER BY attempts_per_second DESC
LIMIT 50;
```

### Uncommon Ports Activity

Identify traffic to non-standard ports that might indicate covert channels:

```sql
SELECT
  srcaddr,
  dstaddr,
  dstport,
  protocol,
  COUNT(*) as connection_count,
  SUM(bytes) as total_bytes,
  action
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND dstport NOT IN (
    20, 21, 22, 23, 25, 53, 80, 110, 143, 443, 465, 587, 993, 995,
    1433, 3306, 3389, 5432, 6379, 8080, 8443
  )
  AND dstport < 1024  -- Well-known ports range
GROUP BY srcaddr, dstaddr, dstport, protocol, action
ORDER BY total_bytes DESC
LIMIT 100;
```

---

## Lateral Movement Detection

### Internal-to-Internal Administrative Protocol Usage

Detect potential lateral movement using admin protocols:

```sql
-- SSH, RDP, WinRM, SMB lateral movement
SELECT
  FROM_UNIXTIME(start) as timestamp,
  srcaddr as source_host,
  dstaddr as destination_host,
  dstport,
  CASE
    WHEN dstport = 22 THEN 'SSH'
    WHEN dstport = 3389 THEN 'RDP'
    WHEN dstport = 5985 THEN 'WinRM-HTTP'
    WHEN dstport = 5986 THEN 'WinRM-HTTPS'
    WHEN dstport = 445 THEN 'SMB'
    WHEN dstport = 135 THEN 'RPC'
  END as protocol_name,
  action,
  bytes,
  packets
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND dstport IN (22, 135, 445, 3389, 5985, 5986)
  AND srcaddr LIKE '10.%'  -- Internal network - adjust to your CIDR
  AND dstaddr LIKE '10.%'  -- Internal network
  AND srcaddr != dstaddr
ORDER BY start;
```

### Host-to-Host Communication Spikes

Identify unusual host pairs communicating (potential lateral movement):

```sql
WITH host_pairs AS (
  SELECT
    srcaddr,
    dstaddr,
    COUNT(*) as connection_count,
    SUM(bytes) as total_bytes,
    MIN(FROM_UNIXTIME(start)) as first_connection,
    MAX(FROM_UNIXTIME(end)) as last_connection
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND srcaddr LIKE '10.%'
    AND dstaddr LIKE '10.%'
  GROUP BY srcaddr, dstaddr
)
SELECT *
FROM host_pairs
WHERE connection_count > 100  -- Adjust threshold
ORDER BY total_bytes DESC
LIMIT 50;
```

### User Workstation to Server SSH/RDP (Unusual Pattern)

```sql
-- Workstations (10.10.x.x) connecting to servers (10.20.x.x) via SSH/RDP
-- Adjust IP ranges to match your network architecture
SELECT
  FROM_UNIXTIME(start) as timestamp,
  srcaddr as workstation,
  dstaddr as server,
  dstport,
  CASE
    WHEN dstport = 22 THEN 'SSH'
    WHEN dstport = 3389 THEN 'RDP'
  END as protocol,
  action,
  bytes
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND srcaddr LIKE '10.10.%'  -- Workstation subnet
  AND dstaddr LIKE '10.20.%'  -- Server subnet
  AND dstport IN (22, 3389)
ORDER BY start;
```

### Pivot Detection (One Host Connecting to Many Internal Hosts)

```sql
SELECT
  srcaddr as potential_pivot_host,
  COUNT(DISTINCT dstaddr) as unique_destinations,
  COUNT(*) as total_connections,
  SUM(bytes) as total_bytes,
  ARRAY_AGG(DISTINCT dstport ORDER BY dstport) as ports_used,
  MIN(FROM_UNIXTIME(start)) as activity_start,
  MAX(FROM_UNIXTIME(end)) as activity_end
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND srcaddr LIKE '10.%'
  AND dstaddr LIKE '10.%'
GROUP BY srcaddr
HAVING COUNT(DISTINCT dstaddr) > 20  -- Adjust threshold
ORDER BY unique_destinations DESC
LIMIT 50;
```

---

## Data Exfiltration

### Large Data Transfers to External IPs

```sql
SELECT
  FROM_UNIXTIME(start) as timestamp,
  srcaddr as internal_host,
  dstaddr as external_ip,
  dstport,
  protocol,
  bytes,
  packets,
  ROUND(bytes / 1024.0 / 1024.0, 2) as megabytes_transferred,
  (end - start) as duration_seconds
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND srcaddr LIKE '10.%'  -- Internal network
  AND NOT (
    dstaddr LIKE '10.%' OR
    dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR dstaddr LIKE '172.18.%' OR
    dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR dstaddr LIKE '172.21.%' OR
    dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR dstaddr LIKE '172.24.%' OR
    dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR dstaddr LIKE '172.27.%' OR
    dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR dstaddr LIKE '172.30.%' OR
    dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%'
  )
  AND bytes > 10485760  -- More than 10 MB
  AND action = 'ACCEPT'
ORDER BY bytes DESC
LIMIT 100;
```

### Unusual Upload Patterns (High Outbound Data)

Detect hosts sending significantly more data than receiving:

```sql
WITH traffic_summary AS (
  SELECT
    interface_id,
    CASE
      WHEN srcaddr LIKE '10.%' THEN srcaddr
      WHEN dstaddr LIKE '10.%' THEN dstaddr
    END as internal_ip,
    SUM(CASE WHEN srcaddr LIKE '10.%' THEN bytes ELSE 0 END) as bytes_sent,
    SUM(CASE WHEN dstaddr LIKE '10.%' THEN bytes ELSE 0 END) as bytes_received
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND (srcaddr LIKE '10.%' OR dstaddr LIKE '10.%')
  GROUP BY
    interface_id,
    CASE
      WHEN srcaddr LIKE '10.%' THEN srcaddr
      WHEN dstaddr LIKE '10.%' THEN dstaddr
    END
)
SELECT
  internal_ip,
  interface_id,
  ROUND(bytes_sent / 1024.0 / 1024.0, 2) as mb_sent,
  ROUND(bytes_received / 1024.0 / 1024.0, 2) as mb_received,
  ROUND(
    CAST(bytes_sent AS DOUBLE) / NULLIF(CAST(bytes_received AS DOUBLE), 0),
    2
  ) as upload_download_ratio
FROM traffic_summary
WHERE bytes_sent > 104857600  -- Sent more than 100 MB
  AND bytes_sent > bytes_received * 3  -- Sent 3x more than received
ORDER BY bytes_sent DESC
LIMIT 50;
```

### Long Duration Outbound Connections (Slow Data Leak)

```sql
SELECT
  FROM_UNIXTIME(start) as start_time,
  FROM_UNIXTIME(end) as end_time,
  (end - start) as duration_seconds,
  ROUND((end - start) / 60.0, 2) as duration_minutes,
  srcaddr as internal_host,
  dstaddr as external_host,
  dstport,
  bytes,
  ROUND(bytes / 1024.0 / 1024.0, 2) as megabytes,
  packets
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND srcaddr LIKE '10.%'
  AND NOT (
    dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR
    dstaddr LIKE '172.17.%' OR dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR
    dstaddr LIKE '172.20.%' OR dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR
    dstaddr LIKE '172.23.%' OR dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR
    dstaddr LIKE '172.26.%' OR dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR
    dstaddr LIKE '172.29.%' OR dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR
    dstaddr LIKE '192.168.%'
  )
  AND (end - start) > 3600  -- Connections longer than 1 hour
  AND action = 'ACCEPT'
ORDER BY duration_seconds DESC
LIMIT 50;
```

### Data Transfer Outside Business Hours

```sql
SELECT
  FROM_UNIXTIME(start) as timestamp,
  HOUR(FROM_UNIXTIME(start)) as hour_of_day,
  srcaddr as internal_host,
  dstaddr as external_host,
  dstport,
  ROUND(bytes / 1024.0 / 1024.0, 2) as megabytes,
  packets
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND srcaddr LIKE '10.%'
  AND NOT (
    dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR
    dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR
    dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR
    dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR
    dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR
    dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%'
  )
  AND (HOUR(FROM_UNIXTIME(start)) < 6 OR HOUR(FROM_UNIXTIME(start)) > 20)  -- Outside 6 AM - 8 PM
  AND bytes > 10485760  -- More than 10 MB
  AND action = 'ACCEPT'
ORDER BY bytes DESC;
```

### File Sharing Protocol Usage (FTP, TFTP, SMB to External)

```sql
SELECT
  FROM_UNIXTIME(start) as timestamp,
  srcaddr as internal_host,
  dstaddr as external_host,
  dstport,
  CASE
    WHEN dstport = 20 OR dstport = 21 THEN 'FTP'
    WHEN dstport = 69 THEN 'TFTP'
    WHEN dstport = 445 THEN 'SMB'
    WHEN dstport = 989 OR dstport = 990 THEN 'FTPS'
  END as protocol,
  bytes,
  ROUND(bytes / 1024.0 / 1024.0, 2) as megabytes,
  action
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND dstport IN (20, 21, 69, 445, 989, 990)
  AND srcaddr LIKE '10.%'
  AND NOT (dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR
           dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR
           dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR
           dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR
           dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR
           dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%')
ORDER BY bytes DESC;
```

---

## Compromised Host Investigation

### All Activity from Potentially Compromised Host

```sql
SELECT
  FROM_UNIXTIME(start) as timestamp,
  srcaddr,
  dstaddr,
  srcport,
  dstport,
  protocol,
  CASE
    WHEN protocol = 1 THEN 'ICMP'
    WHEN protocol = 6 THEN 'TCP'
    WHEN protocol = 17 THEN 'UDP'
    ELSE CAST(protocol AS VARCHAR)
  END as protocol_name,
  action,
  bytes,
  packets,
  (end - start) as duration_seconds
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND (srcaddr = '10.0.1.50' OR dstaddr = '10.0.1.50')
ORDER BY start;
```

### Identify First and Last Activity of Compromised Host

```sql
SELECT
  'Outbound' as direction,
  MIN(FROM_UNIXTIME(start)) as first_activity,
  MAX(FROM_UNIXTIME(end)) as last_activity,
  COUNT(*) as total_connections,
  COUNT(DISTINCT dstaddr) as unique_destinations,
  SUM(bytes) as total_bytes
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND srcaddr = '10.0.1.50'

UNION ALL

SELECT
  'Inbound' as direction,
  MIN(FROM_UNIXTIME(start)) as first_activity,
  MAX(FROM_UNIXTIME(end)) as last_activity,
  COUNT(*) as total_connections,
  COUNT(DISTINCT srcaddr) as unique_sources,
  SUM(bytes) as total_bytes
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND dstaddr = '10.0.1.50';
```

### External IPs Contacted by Compromised Host

```sql
SELECT
  dstaddr as external_ip,
  COUNT(*) as connection_count,
  SUM(bytes) as total_bytes,
  ROUND(SUM(bytes) / 1024.0 / 1024.0, 2) as total_mb,
  ARRAY_AGG(DISTINCT dstport ORDER BY dstport) as ports_contacted,
  MIN(FROM_UNIXTIME(start)) as first_contact,
  MAX(FROM_UNIXTIME(end)) as last_contact
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND srcaddr = '10.0.1.50'
  AND NOT (
    dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR
    dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR
    dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR
    dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR
    dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR
    dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%'
  )
GROUP BY dstaddr
ORDER BY total_bytes DESC;
```

### Internal Hosts Contacted by Compromised Host (Lateral Movement)

```sql
SELECT
  dstaddr as internal_host,
  COUNT(*) as connection_count,
  ARRAY_AGG(DISTINCT dstport ORDER BY dstport) as ports_accessed,
  SUM(bytes) as total_bytes,
  MIN(FROM_UNIXTIME(start)) as first_contact,
  MAX(FROM_UNIXTIME(end)) as last_contact,
  SUM(CASE WHEN action = 'ACCEPT' THEN 1 ELSE 0 END) as successful_connections,
  SUM(CASE WHEN action = 'REJECT' THEN 1 ELSE 0 END) as blocked_connections
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND srcaddr = '10.0.1.50'
  AND dstaddr LIKE '10.%'
  AND srcaddr != dstaddr
GROUP BY dstaddr
ORDER BY connection_count DESC;
```

### Hosts That Communicated with Compromised Host

```sql
SELECT
  srcaddr as source_host,
  COUNT(*) as connection_count,
  ARRAY_AGG(DISTINCT dstport ORDER BY dstport) as ports_used,
  SUM(bytes) as total_bytes,
  MIN(FROM_UNIXTIME(start)) as first_connection,
  MAX(FROM_UNIXTIME(end)) as last_connection
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
  AND dstaddr = '10.0.1.50'
  AND srcaddr LIKE '10.%'
GROUP BY srcaddr
ORDER BY connection_count DESC;
```

---

## Timeline Analysis

### Hourly Traffic Timeline for Investigation Period

```sql
SELECT
  DATE_FORMAT(FROM_UNIXTIME(start), '%Y-%m-%d %H:00') as hour,
  COUNT(*) as flow_count,
  COUNT(DISTINCT srcaddr) as unique_sources,
  COUNT(DISTINCT dstaddr) as unique_destinations,
  SUM(bytes) as total_bytes,
  ROUND(SUM(bytes) / 1024.0 / 1024.0, 2) as total_mb,
  SUM(CASE WHEN action = 'ACCEPT' THEN 1 ELSE 0 END) as accepted_flows,
  SUM(CASE WHEN action = 'REJECT' THEN 1 ELSE 0 END) as rejected_flows
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-15' AND '2024-01-16'
GROUP BY DATE_FORMAT(FROM_UNIXTIME(start), '%Y-%m-%d %H:00')
ORDER BY hour;
```

### Minute-by-Minute Activity During Incident Window

```sql
SELECT
  DATE_FORMAT(FROM_UNIXTIME(start), '%Y-%m-%d %H:%i') as minute,
  COUNT(*) as flow_count,
  SUM(bytes) as total_bytes,
  COUNT(DISTINCT srcaddr) as unique_sources,
  COUNT(DISTINCT dstaddr) as unique_destinations
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND start >= UNIX_TIMESTAMP(TIMESTAMP '2024-01-15 14:30:00')
  AND end <= UNIX_TIMESTAMP(TIMESTAMP '2024-01-15 15:30:00')
GROUP BY DATE_FORMAT(FROM_UNIXTIME(start), '%Y-%m-%d %H:%i')
ORDER BY minute;
```

### First Appearance of Suspicious Activity

```sql
-- First instance of connection to known bad IP
SELECT
  MIN(FROM_UNIXTIME(start)) as first_occurrence,
  srcaddr as internal_host,
  dstaddr as malicious_ip,
  dstport,
  interface_id
FROM vpc_flow_logs.flow_logs
WHERE dt BETWEEN '2024-01-14' AND '2024-01-16'
  AND dstaddr = '203.0.113.10'  -- Known malicious IP
GROUP BY srcaddr, dstaddr, dstport, interface_id
ORDER BY first_occurrence;
```

### Activity Correlation (Multiple Events in Same Timeframe)

```sql
-- Find hosts with multiple suspicious activities in same 5-minute window
WITH suspicious_windows AS (
  SELECT
    srcaddr,
    FLOOR(start / 300) * 300 as time_window,  -- 5-minute buckets
    COUNT(DISTINCT dstaddr) as unique_destinations,
    COUNT(DISTINCT dstport) as unique_ports,
    COUNT(*) as connection_attempts,
    SUM(CASE WHEN action = 'REJECT' THEN 1 ELSE 0 END) as rejected_count
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND srcaddr LIKE '10.%'
  GROUP BY srcaddr, FLOOR(start / 300)
)
SELECT
  FROM_UNIXTIME(time_window) as window_start,
  srcaddr,
  unique_destinations,
  unique_ports,
  connection_attempts,
  rejected_count
FROM suspicious_windows
WHERE unique_ports > 10 OR rejected_count > 20
ORDER BY time_window, rejected_count DESC;
```

---

## Network-Based Attacks

### DDoS Detection (High Connection Rate to Single Target)

```sql
SELECT
  dstaddr as target,
  dstport,
  COUNT(DISTINCT srcaddr) as unique_sources,
  COUNT(*) as total_connections,
  SUM(packets) as total_packets,
  SUM(bytes) as total_bytes,
  MIN(FROM_UNIXTIME(start)) as attack_start,
  MAX(FROM_UNIXTIME(end)) as attack_end
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
GROUP BY dstaddr, dstport
HAVING COUNT(*) > 10000  -- Adjust threshold based on normal traffic
ORDER BY total_connections DESC
LIMIT 50;
```

### SYN Flood Detection (Many Small Packets, Short Durations)

```sql
SELECT
  dstaddr as target,
  dstport,
  COUNT(*) as connection_attempts,
  AVG(packets) as avg_packets,
  AVG(bytes) as avg_bytes,
  AVG(end - start) as avg_duration,
  COUNT(DISTINCT srcaddr) as unique_sources
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND protocol = 6  -- TCP
  AND packets < 10
  AND (end - start) < 5
GROUP BY dstaddr, dstport
HAVING COUNT(*) > 1000
ORDER BY connection_attempts DESC;
```

### Amplification Attack Sources (Small Request, Large Response)

```sql
-- Identify hosts potentially being used in amplification attacks
-- Looking for small outbound packets with large inbound responses
WITH outbound AS (
  SELECT
    srcaddr as internal_host,
    dstaddr as external_host,
    dstport,
    SUM(bytes) as bytes_sent,
    SUM(packets) as packets_sent
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND srcaddr LIKE '10.%'
    AND protocol = 17  -- UDP (common for amplification)
  GROUP BY srcaddr, dstaddr, dstport
),
inbound AS (
  SELECT
    dstaddr as internal_host,
    srcaddr as external_host,
    srcport as dstport,
    SUM(bytes) as bytes_received,
    SUM(packets) as packets_received
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND dstaddr LIKE '10.%'
    AND protocol = 17
  GROUP BY dstaddr, srcaddr, srcport
)
SELECT
  o.internal_host,
  o.external_host,
  o.dstport,
  o.bytes_sent,
  i.bytes_received,
  ROUND(CAST(i.bytes_received AS DOUBLE) / NULLIF(CAST(o.bytes_sent AS DOUBLE), 0), 2) as amplification_factor
FROM outbound o
INNER JOIN inbound i
  ON o.internal_host = i.internal_host
  AND o.external_host = i.external_host
  AND o.dstport = i.dstport
WHERE i.bytes_received > o.bytes_sent * 10  -- 10x amplification
ORDER BY amplification_factor DESC;
```

### ICMP Flood Detection

```sql
SELECT
  srcaddr,
  dstaddr,
  COUNT(*) as icmp_count,
  SUM(packets) as total_packets,
  SUM(bytes) as total_bytes,
  MIN(FROM_UNIXTIME(start)) as flood_start,
  MAX(FROM_UNIXTIME(end)) as flood_end
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND protocol = 1  -- ICMP
GROUP BY srcaddr, dstaddr
HAVING COUNT(*) > 1000  -- Adjust threshold
ORDER BY icmp_count DESC;
```

### DNS Tunneling Detection (Unusual DNS Traffic Volume)

```sql
SELECT
  srcaddr as internal_host,
  dstaddr as dns_server,
  COUNT(*) as dns_queries,
  SUM(bytes) as total_bytes,
  ROUND(SUM(bytes) / 1024.0, 2) as total_kb,
  AVG(bytes) as avg_query_size,
  MIN(FROM_UNIXTIME(start)) as first_query,
  MAX(FROM_UNIXTIME(end)) as last_query
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND dstport = 53
  AND protocol = 17  -- UDP
GROUP BY srcaddr, dstaddr
HAVING SUM(bytes) > 1048576  -- More than 1 MB of DNS traffic
   OR COUNT(*) > 10000  -- More than 10k queries
ORDER BY total_bytes DESC;
```

---

## Persistence & C2 Communication

### Beaconing Detection (Regular Periodic Connections)

```sql
-- Identify potential C2 beaconing by looking for regular intervals
WITH connection_intervals AS (
  SELECT
    srcaddr,
    dstaddr,
    dstport,
    start,
    LAG(start) OVER (PARTITION BY srcaddr, dstaddr, dstport ORDER BY start) as prev_start,
    start - LAG(start) OVER (PARTITION BY srcaddr, dstaddr, dstport ORDER BY start) as interval_seconds
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND srcaddr LIKE '10.%'
    AND NOT (dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR
             dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR
             dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR
             dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR
             dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR
             dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%')
)
SELECT
  srcaddr as internal_host,
  dstaddr as external_host,
  dstport,
  COUNT(*) as connection_count,
  ROUND(AVG(interval_seconds), 2) as avg_interval_seconds,
  ROUND(STDDEV(interval_seconds), 2) as interval_stddev,
  MIN(interval_seconds) as min_interval,
  MAX(interval_seconds) as max_interval
FROM connection_intervals
WHERE interval_seconds IS NOT NULL
GROUP BY srcaddr, dstaddr, dstport
HAVING COUNT(*) > 10
  AND STDDEV(interval_seconds) < 60  -- Low variation indicates beaconing
  AND AVG(interval_seconds) BETWEEN 30 AND 3600  -- Beacon interval between 30s and 1h
ORDER BY interval_stddev ASC, connection_count DESC
LIMIT 50;
```

### Long-Lived Connections to External Hosts (Potential C2)

```sql
SELECT
  FROM_UNIXTIME(start) as start_time,
  FROM_UNIXTIME(end) as end_time,
  ROUND((end - start) / 3600.0, 2) as duration_hours,
  srcaddr as internal_host,
  dstaddr as external_host,
  dstport,
  bytes,
  packets,
  interface_id
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND srcaddr LIKE '10.%'
  AND NOT (dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR
           dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR
           dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR
           dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR
           dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR
           dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%')
  AND (end - start) > 7200  -- Connections longer than 2 hours
  AND action = 'ACCEPT'
ORDER BY (end - start) DESC;
```

### Unusual Outbound Ports (Potential C2 over Non-Standard Ports)

```sql
SELECT
  srcaddr as internal_host,
  dstaddr as external_host,
  dstport,
  protocol,
  COUNT(*) as connection_count,
  SUM(bytes) as total_bytes,
  MIN(FROM_UNIXTIME(start)) as first_seen,
  MAX(FROM_UNIXTIME(end)) as last_seen
FROM vpc_flow_logs.flow_logs
WHERE dt = '2024-01-15'
  AND srcaddr LIKE '10.%'
  AND NOT (dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR
           dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR
           dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR
           dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR
           dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR
           dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%')
  AND dstport NOT IN (53, 80, 123, 443, 8080, 8443)  -- Exclude common legitimate ports
  AND dstport > 1024  -- Focus on high ports
GROUP BY srcaddr, dstaddr, dstport, protocol
ORDER BY connection_count DESC
LIMIT 100;
```

---

## Baseline Deviations

### Hosts with Unusual Traffic Volume (Statistical Anomaly)

```sql
-- Compare today's traffic to average (requires historical data)
WITH daily_traffic AS (
  SELECT
    interface_id,
    CASE
      WHEN srcaddr LIKE '10.%' THEN srcaddr
      WHEN dstaddr LIKE '10.%' THEN dstaddr
    END as internal_ip,
    dt,
    SUM(bytes) as daily_bytes
  FROM vpc_flow_logs.flow_logs
  WHERE dt BETWEEN '2024-01-08' AND '2024-01-15'
    AND (srcaddr LIKE '10.%' OR dstaddr LIKE '10.%')
  GROUP BY
    interface_id,
    CASE
      WHEN srcaddr LIKE '10.%' THEN srcaddr
      WHEN dstaddr LIKE '10.%' THEN dstaddr
    END,
    dt
),
stats AS (
  SELECT
    internal_ip,
    interface_id,
    AVG(daily_bytes) as avg_bytes,
    STDDEV(daily_bytes) as stddev_bytes
  FROM daily_traffic
  WHERE dt < '2024-01-15'  -- Historical baseline
  GROUP BY internal_ip, interface_id
),
today AS (
  SELECT
    internal_ip,
    interface_id,
    daily_bytes as today_bytes
  FROM daily_traffic
  WHERE dt = '2024-01-15'
)
SELECT
  t.internal_ip,
  t.interface_id,
  ROUND(s.avg_bytes / 1024.0 / 1024.0, 2) as avg_mb_baseline,
  ROUND(t.today_bytes / 1024.0 / 1024.0, 2) as today_mb,
  ROUND(
    (t.today_bytes - s.avg_bytes) / NULLIF(s.stddev_bytes, 0),
    2
  ) as std_deviations
FROM today t
INNER JOIN stats s
  ON t.internal_ip = s.internal_ip
  AND t.interface_id = s.interface_id
WHERE s.stddev_bytes > 0
  AND ABS((t.today_bytes - s.avg_bytes) / s.stddev_bytes) > 3  -- More than 3 std devs
ORDER BY ABS((t.today_bytes - s.avg_bytes) / s.stddev_bytes) DESC;
```

### New External Destinations (First Time Connections)

```sql
-- Find external IPs contacted for the first time
-- Requires comparison between investigation period and baseline period
WITH baseline_destinations AS (
  SELECT DISTINCT dstaddr
  FROM vpc_flow_logs.flow_logs
  WHERE dt BETWEEN '2024-01-08' AND '2024-01-14'  -- Previous week
    AND srcaddr LIKE '10.%'
    AND NOT (dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR
             dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR
             dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR
             dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR
             dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR
             dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%')
)
SELECT
  f.srcaddr as internal_host,
  f.dstaddr as new_external_ip,
  f.dstport,
  COUNT(*) as connection_count,
  SUM(f.bytes) as total_bytes,
  MIN(FROM_UNIXTIME(f.start)) as first_connection
FROM vpc_flow_logs.flow_logs f
LEFT JOIN baseline_destinations b ON f.dstaddr = b.dstaddr
WHERE f.dt = '2024-01-15'
  AND f.srcaddr LIKE '10.%'
  AND NOT (f.dstaddr LIKE '10.%' OR f.dstaddr LIKE '172.16.%' OR f.dstaddr LIKE '172.17.%' OR
           f.dstaddr LIKE '172.18.%' OR f.dstaddr LIKE '172.19.%' OR f.dstaddr LIKE '172.20.%' OR
           f.dstaddr LIKE '172.21.%' OR f.dstaddr LIKE '172.22.%' OR f.dstaddr LIKE '172.23.%' OR
           f.dstaddr LIKE '172.24.%' OR f.dstaddr LIKE '172.25.%' OR f.dstaddr LIKE '172.26.%' OR
           f.dstaddr LIKE '172.27.%' OR f.dstaddr LIKE '172.28.%' OR f.dstaddr LIKE '172.29.%' OR
           f.dstaddr LIKE '172.30.%' OR f.dstaddr LIKE '172.31.%' OR f.dstaddr LIKE '192.168.%')
  AND b.dstaddr IS NULL  -- Not in baseline
GROUP BY f.srcaddr, f.dstaddr, f.dstport
ORDER BY total_bytes DESC;
```

---

## Multi-Stage Attack Chains

### Kill Chain Analysis (Reconnaissance → Exploit → C2 → Exfiltration)

```sql
-- Identify hosts showing multiple stages of attack behavior
WITH reconnaissance AS (
  SELECT DISTINCT srcaddr
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND srcaddr LIKE '10.%'
  GROUP BY srcaddr, dstaddr
  HAVING COUNT(DISTINCT dstport) > 15  -- Port scanning
),
admin_access AS (
  SELECT DISTINCT srcaddr
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND dstport IN (22, 3389, 5985, 5986)  -- Admin protocols
    AND action = 'ACCEPT'
),
c2_activity AS (
  SELECT DISTINCT srcaddr
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND srcaddr LIKE '10.%'
    AND NOT (dstaddr LIKE '10.%' OR dstaddr LIKE '172.16.%' OR dstaddr LIKE '172.17.%' OR
             dstaddr LIKE '172.18.%' OR dstaddr LIKE '172.19.%' OR dstaddr LIKE '172.20.%' OR
             dstaddr LIKE '172.21.%' OR dstaddr LIKE '172.22.%' OR dstaddr LIKE '172.23.%' OR
             dstaddr LIKE '172.24.%' OR dstaddr LIKE '172.25.%' OR dstaddr LIKE '172.26.%' OR
             dstaddr LIKE '172.27.%' OR dstaddr LIKE '172.28.%' OR dstaddr LIKE '172.29.%' OR
             dstaddr LIKE '172.30.%' OR dstaddr LIKE '172.31.%' OR dstaddr LIKE '192.168.%')
  GROUP BY srcaddr, dstaddr
  HAVING (MAX(end) - MIN(start)) > 3600  -- Long-lived connections
),
exfiltration AS (
  SELECT DISTINCT srcaddr
  FROM vpc_flow_logs.flow_logs
  WHERE dt = '2024-01-15'
    AND srcaddr LIKE '10.%'
    AND bytes > 10485760  -- Large data transfers
)
SELECT
  COALESCE(r.srcaddr, a.srcaddr, c.srcaddr, e.srcaddr) as suspicious_host,
  CASE WHEN r.srcaddr IS NOT NULL THEN 'YES' ELSE 'NO' END as reconnaissance,
  CASE WHEN a.srcaddr IS NOT NULL THEN 'YES' ELSE 'NO' END as admin_access,
  CASE WHEN c.srcaddr IS NOT NULL THEN 'YES' ELSE 'NO' END as c2_beaconing,
  CASE WHEN e.srcaddr IS NOT NULL THEN 'YES' ELSE 'NO' END as large_transfers,
  (CASE WHEN r.srcaddr IS NOT NULL THEN 1 ELSE 0 END +
   CASE WHEN a.srcaddr IS NOT NULL THEN 1 ELSE 0 END +
   CASE WHEN c.srcaddr IS NOT NULL THEN 1 ELSE 0 END +
   CASE WHEN e.srcaddr IS NOT NULL THEN 1 ELSE 0 END) as attack_stage_count
FROM reconnaissance r
FULL OUTER JOIN admin_access a ON r.srcaddr = a.srcaddr
FULL OUTER JOIN c2_activity c ON COALESCE(r.srcaddr, a.srcaddr) = c.srcaddr
FULL OUTER JOIN exfiltration e ON COALESCE(r.srcaddr, a.srcaddr, c.srcaddr) = e.srcaddr
WHERE (CASE WHEN r.srcaddr IS NOT NULL THEN 1 ELSE 0 END +
       CASE WHEN a.srcaddr IS NOT NULL THEN 1 ELSE 0 END +
       CASE WHEN c.srcaddr IS NOT NULL THEN 1 ELSE 0 END +
       CASE WHEN e.srcaddr IS NOT NULL THEN 1 ELSE 0 END) >= 2  -- At least 2 stages
ORDER BY attack_stage_count DESC;
```

---

## Query Performance Tips

1. **Always specify partitions**: Use `WHERE dt = 'YYYY-MM-DD'` to limit data scanned
2. **Use time ranges**: Further filter with `start` and `end` Unix timestamps
3. **Limit result sets**: Use `LIMIT` when exploring data
4. **Create targeted partitions**: Load only partitions you need for investigation
5. **Use columnar format**: Consider converting to Parquet for repeated analysis
6. **Monitor costs**: Check "Data scanned" in query results to estimate costs

## Investigation Workflow Example

```sql
-- Step 1: Identify the scope
-- Run: "All Activity Involving Suspicious IP Address"

-- Step 2: Find affected internal hosts
-- Run: "Find All Internal IPs Communicating with Known Malicious IP"

-- Step 3: For each affected host, investigate
-- Run: "All Activity from Potentially Compromised Host"
-- Run: "External IPs Contacted by Compromised Host"
-- Run: "Internal Hosts Contacted by Compromised Host"

-- Step 4: Look for lateral movement
-- Run: "Internal-to-Internal Administrative Protocol Usage"
-- Run: "Pivot Detection"

-- Step 5: Check for data exfiltration
-- Run: "Large Data Transfers to External IPs"
-- Run: "Unusual Upload Patterns"

-- Step 6: Build timeline
-- Run: "Minute-by-Minute Activity During Incident Window"
-- Run: "First Appearance of Suspicious Activity"

-- Step 7: Assess scope with kill chain analysis
-- Run: "Kill Chain Analysis"
```

## Additional Resources

- [VPC Flow Logs Field Descriptions](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html#flow-logs-fields)
- [Athena Performance Tuning](https://docs.aws.amazon.com/athena/latest/ug/performance-tuning.html)
- [MITRE ATT&CK Framework](https://attack.mitre.org/)
- [AWS Security Best Practices](https://docs.aws.amazon.com/security/)

## Important Notes

- **Adjust IP ranges**: All queries use example RFC 1918 ranges (10.x, 172.16-31.x, 192.168.x). Modify to match your environment
- **Tune thresholds**: Adjust COUNT, bytes, and time thresholds based on your baseline traffic
- **Consider context**: High traffic volume might be normal for some hosts (backup servers, proxies, etc.)
- **Correlate with other logs**: VPC Flow Logs show network traffic but not payload. Correlate with CloudTrail, application logs, and endpoint detection tools
- **Test queries**: Always test on a small dataset first to verify query performance
