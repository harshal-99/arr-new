#!/usr/bin/env python3
import subprocess
import time
import os
import sys

# Define constants
TOTAL_SIZE_GB = 924.73
TOTAL_SIZE_BYTES = 992928826682  # total size in bytes from dry run was 924.73G

def get_nas_info():
    # SSH command to get size and screen status
    cmd = "sshpass -p 'YOUR_SSH_PASSWORD' ssh -o StrictHostKeyChecking=no harshal@192.168.0.236 " \
          "\"du -s /share/CACHEDEV1_DATA/data && (screen -ls | grep -q nas_copy && echo 'RUNNING' || echo 'STOPPED')\""
    try:
        res = subprocess.check_output(cmd, shell=True).decode('utf-8').strip().split('\n')
        # Skip warning lines from SSH/QNAP
        cleaned_res = [line for line in res if not line.startswith("Could not chdir") and not line.startswith("Warning:")]
        if len(cleaned_res) >= 2:
            size_kb = int(cleaned_res[0].split()[0])
            status = cleaned_res[1]
        elif len(cleaned_res) == 1:
            size_kb = int(cleaned_res[0].split()[0])
            status = "STOPPED"
        else:
            raise ValueError("Empty response")
        return size_kb, status
    except Exception as e:
        print(f"Error connecting to NAS: {e}")
        sys.exit(1)

def get_current_file():
    cmd = "sshpass -p 'YOUR_SSH_PASSWORD' ssh -o StrictHostKeyChecking=no harshal@192.168.0.236 " \
          "\"tail -n 20 /share/CACHEDEV1_DATA/data/copy.log | grep -v -E '^[[:space:]]+[0-9]+[[:space:]]+' | tail -n 1\""
    try:
        res = subprocess.check_output(cmd, shell=True).decode('utf-8').strip().split('\n')
        cleaned_res = [line for line in res if not line.startswith("Could not chdir") and not line.startswith("Warning:")]
        if cleaned_res:
            return cleaned_res[-1].strip()
        return "Unknown"
    except:
        return "Unknown"

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    start_time_file = os.path.join(script_dir, "copy_start_time.txt")
    
    if not os.path.exists(start_time_file):
        print("Start time file not found.")
        sys.exit(1)
        
    with open(start_time_file, 'r') as f:
        start_time = int(f.read().strip())
        
    current_time = int(time.time())
    elapsed = current_time - start_time
    if elapsed <= 0:
        elapsed = 1
        
    size_kb, status = get_nas_info()
    copied_bytes = size_kb * 1024
    
    # Calculate speed, remaining, ETA
    copied_gb = copied_bytes / (1024**3)
    speed_mb_s = (copied_bytes / elapsed) / (1024**2)
    
    remaining_bytes = TOTAL_SIZE_BYTES - copied_bytes
    if remaining_bytes < 0:
        remaining_bytes = 0
    remaining_gb = remaining_bytes / (1024**3)
    
    if speed_mb_s > 0 and copied_bytes > 0:
        eta_seconds = remaining_bytes / (copied_bytes / elapsed)
    else:
        eta_seconds = 0
        
    # Format ETA
    eta_hours = int(eta_seconds // 3600)
    eta_minutes = int((eta_seconds % 3600) // 60)
    eta_str = f"{eta_hours}h {eta_minutes}m" if eta_hours > 0 else f"{eta_minutes}m"
    
    percent = (copied_bytes / TOTAL_SIZE_BYTES) * 100
    if percent > 100:
        percent = 100.0
        
    current_file = get_current_file()
    
    # Build report
    report = []
    report.append("### NAS Copy Progress Update")
    report.append(f"* **Status**: {status}")
    report.append(f"* **Progress**: {percent:.2f}% ({copied_gb:.2f} GB / {TOTAL_SIZE_GB:.2f} GB)")
    report.append(f"* **Transfer Speed**: {speed_mb_s:.2f} MB/s (Average)")
    report.append(f"* **Remaining Data**: {remaining_gb:.2f} GB")
    if status == "RUNNING" and speed_mb_s > 0 and percent < 100:
        report.append(f"* **ETA**: {eta_str}")
    else:
        report.append(f"* **ETA**: N/A")
    report.append(f"* **Current File**: `{current_file}`")
    
    print("\n".join(report))

if __name__ == "__main__":
    main()
